// Package e2e drives a built minipg binary end to end: it creates .pgdbs,
// starts and stops servers, and connects to them as an app would.
//
//	make build && (cd .dev/e2e && go test -v)
//
// MINIPG names the binary (default ../../minipg). Every test gets its own
// HOME and runtime directory; the unpacked root is shared through
// MINIPG_E2E_CACHE (default $TMPDIR/minipg-e2e-cache), so only the first
// test pays for unpacking it.
package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

var bin string

func TestMain(m *testing.M) {
	bin = os.Getenv("MINIPG")
	if bin == "" {
		bin = "../../minipg"
	}
	abs, err := filepath.Abs(bin)
	if err != nil {
		panic(err)
	}
	bin = abs
	if _, err := os.Stat(bin); err != nil {
		fmt.Fprintf(os.Stderr, "e2e: no minipg binary at %s (set MINIPG)\n", bin)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

// env is one test's world: a working directory and the environment minipg
// runs in.
type env struct {
	t    *testing.T
	dir  string
	vars []string
}

func newEnv(t *testing.T) *env {
	t.Helper()
	dir := t.TempDir()
	cache := os.Getenv("MINIPG_E2E_CACHE")
	if cache == "" {
		cache = filepath.Join(os.TempDir(), "minipg-e2e-cache")
	}
	home := filepath.Join(dir, "home")
	run := filepath.Join(dir, "run")
	for _, d := range []string{home, run, cache} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	e := &env{t: t, dir: dir}
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "XDG_STATE_HOME", "MINIPG_IDLE":
			continue
		}
		if strings.HasPrefix(k, "POSTGRES_") || strings.HasPrefix(k, "PG") {
			continue
		}
		e.vars = append(e.vars, kv)
	}
	e.vars = append(e.vars, "HOME="+home, "XDG_CACHE_HOME="+cache, "XDG_RUNTIME_DIR="+run)
	t.Cleanup(e.stopAll)
	return e
}

func (e *env) path(name string) string { return filepath.Join(e.dir, name) }

func (e *env) cmd(stdin string, extra []string, args ...string) *exec.Cmd {
	c := exec.Command(bin, args...)
	c.Dir = e.dir
	c.Env = append(append([]string{}, e.vars...), extra...)
	if stdin != "" {
		c.Stdin = strings.NewReader(stdin)
	}
	return c
}

// run runs minipg and returns its stdout, stderr and exit code.
func (e *env) run(args ...string) (string, string, int) {
	return e.runWith("", nil, args...)
}

func (e *env) runWith(stdin string, extra []string, args ...string) (string, string, int) {
	e.t.Helper()
	c := e.cmd(stdin, extra, args...)
	var out, errb bytes.Buffer
	c.Stdout, c.Stderr = &out, &errb
	err := c.Run()
	code := 0
	if err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			e.t.Fatalf("minipg %v: %v", args, err)
		}
		code = ee.ExitCode()
	}
	return out.String(), errb.String(), code
}

// must runs minipg and fails the test unless it exits 0.
func (e *env) must(args ...string) string {
	e.t.Helper()
	out, errs, code := e.run(args...)
	if code != 0 {
		e.t.Fatalf("minipg %v: exit %d\nstdout: %s\nstderr: %s", args, code, out, errs)
	}
	return out
}

// query runs one statement through the bare form and returns psql's
// unaligned, tuples-only output.
func (e *env) query(pgdb, sql string) string {
	e.t.Helper()
	return strings.TrimSpace(e.must("exec", pgdb, "--", "psql", "-tAX", "-c", sql))
}

func (e *env) url(pgdb string) string {
	e.t.Helper()
	return strings.TrimSpace(e.must("url", pgdb))
}

func (e *env) connect(url string) *pgx.Conn {
	e.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	c, err := pgx.Connect(ctx, url)
	if err != nil {
		e.t.Fatalf("connect %s: %v", url, err)
	}
	return c
}

// stopAll stops every server this test's .pgdbs have, so none outlives it.
func (e *env) stopAll() {
	entries, _ := os.ReadDir(e.dir)
	for _, de := range entries {
		if strings.HasSuffix(de.Name(), ".pgdb") {
			c := e.cmd("", nil, "stop", de.Name())
			c.Run()
		}
	}
}

type status struct {
	running bool
	port    int
	clients int
}

func (e *env) status(pgdb string) status {
	e.t.Helper()
	out, errs, code := e.run("status", pgdb)
	switch code {
	case 3:
		return status{}
	case 0:
	default:
		e.t.Fatalf("status: exit %d: %s", code, errs)
	}
	s := status{running: true, clients: -1}
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		switch f[0] {
		case "listen":
			_, p, _ := strings.Cut(f[1], ":")
			s.port, _ = strconv.Atoi(p)
		case "clients":
			s.clients, _ = strconv.Atoi(f[1])
		}
	}
	return s
}

func waitFor(t *testing.T, what string, d time.Duration, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for !f() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out after %v waiting for %s", d, what)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func readToml(t *testing.T, pgdb string) map[string]string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(pgdb, "minipg.toml"))
	if err != nil {
		t.Fatal(err)
	}
	m := map[string]string{}
	for _, line := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(line, " = ")
		if ok && !strings.HasPrefix(k, "#") {
			m[k] = strings.Trim(v, `"`)
		}
	}
	return m
}

func TestVersionAndHelp(t *testing.T) {
	e := newEnv(t)
	if out := e.must("-v"); !strings.HasPrefix(out, "minipg ") {
		t.Errorf("-v printed %q", out)
	}
	if out := e.must("--help"); !strings.Contains(out, "minipg <pgdb>") {
		t.Errorf("--help printed %q", out)
	}
	if _, _, code := e.run("serve"); code != 2 {
		t.Errorf("serve without a .pgdb: exit %d, want 2", code)
	}
}

func TestInit(t *testing.T) {
	e := newEnv(t)
	out := e.must("init", "app.pgdb")
	if !strings.Contains(out, "created app.pgdb") {
		t.Errorf("init printed %q", out)
	}
	for _, f := range []string{"minipg.toml", "pgdata/PG_VERSION"} {
		if _, err := os.Stat(e.path("app.pgdb/" + f)); err != nil {
			t.Errorf("%s: %v", f, err)
		}
	}
	m := readToml(t, e.path("app.pgdb"))
	if m["database"] != "app" || m["user"] != "postgres" || len(m["password"]) < 16 || m["format"] != "1" {
		t.Errorf("minipg.toml: %v", m)
	}
	if m["pg.last_opened"] == "" || m["pg.arch"] == "" {
		t.Errorf("minipg.toml doesn't record the version and arch: %v", m)
	}
	if st, err := os.Stat(e.path("app.pgdb/minipg.toml")); err == nil && st.Mode().Perm() != 0o600 {
		t.Errorf("minipg.toml mode %v, want 0600", st.Mode().Perm())
	}
	if e.status("app.pgdb").running {
		t.Errorf("init left a server running")
	}
	if _, errs, code := e.run("init", "app.pgdb"); code == 0 || !strings.Contains(errs, "exists") {
		t.Errorf("init on an existing path: exit %d, %q", code, errs)
	}
	// The database is named after the file.
	if got := e.query("app.pgdb", "select current_database()"); got != "app" {
		t.Errorf("current_database() = %q", got)
	}
}

func TestBareFormAndPersistence(t *testing.T) {
	e := newEnv(t)
	// The bare form creates a missing .pgdb.
	out, errs, code := e.run("data.pgdb", "create table t (a int); insert into t values (1), (2)")
	if code != 0 || !strings.Contains(errs, "creating data.pgdb") {
		t.Fatalf("bare form: exit %d\n%s\n%s", code, out, errs)
	}
	if !strings.Contains(out, "INSERT 0 2") {
		t.Errorf("bare form printed %q", out)
	}
	// Statements from stdin.
	out, _, code = e.runWith("select sum(a) from t;\n", nil, "data.pgdb")
	if code != 0 || !strings.Contains(out, "3") {
		t.Errorf("stdin: exit %d, %q", code, out)
	}
	// Back-to-back commands share one server.
	s1 := e.status("data.pgdb")
	e.query("data.pgdb", "select 1")
	s2 := e.status("data.pgdb")
	if !s1.running || s1.port != s2.port {
		t.Errorf("status before and after: %+v %+v", s1, s2)
	}
	// Data survives a stop and a fresh server.
	e.must("stop", "data.pgdb")
	if e.status("data.pgdb").running {
		t.Fatal("still running after stop")
	}
	if got := e.query("data.pgdb", "select string_agg(a::text, ',' order by a) from t"); got != "1,2" {
		t.Errorf("after restart: %q", got)
	}
	// A SQL error is psql's exit code.
	if _, _, code := e.run("data.pgdb", "select * from nope"); code == 0 {
		t.Errorf("failing statement exited 0")
	}
}

func TestAppConnection(t *testing.T) {
	e := newEnv(t)
	e.must("init", "app.pgdb")
	url := e.url("app.pgdb")
	if !strings.HasPrefix(url, "postgres://postgres:") || !strings.HasSuffix(url, "/app") {
		t.Fatalf("url = %q", url)
	}
	// Start the server, then connect as an app with the URL.
	e.query("app.pgdb", "select 1")
	url = e.url("app.pgdb")
	conn := e.connect(url)
	defer conn.Close(context.Background())
	ctx := context.Background()
	if _, err := conn.Exec(ctx, "create table kv (k text primary key, v text)"); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, "insert into kv values ('a', 'b')"); err != nil {
		t.Fatal(err)
	}
	// The server counts the app's connection.
	waitFor(t, "clients = 1", 10*time.Second, func() bool { return e.status("app.pgdb").clients == 1 })
	// A wrong password is refused: SCRAM, not trust.
	bad := strings.Replace(url, "postgres:", "postgres:x", 1)
	ctx2, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if c, err := pgx.Connect(ctx2, bad); err == nil {
		c.Close(ctx)
		t.Errorf("connected with a wrong password")
	}
	// Postgres listens on loopback only.
	var listen string
	if err := conn.QueryRow(ctx, "show listen_addresses").Scan(&listen); err != nil || listen != "127.0.0.1" {
		t.Errorf("listen_addresses = %q, %v", listen, err)
	}
	var jit string
	if err := conn.QueryRow(ctx, "show jit").Scan(&jit); err != nil || jit != "off" {
		t.Errorf("jit = %q, %v", jit, err)
	}
}

func TestExec(t *testing.T) {
	e := newEnv(t)
	e.must("init", "app.pgdb")
	e.query("app.pgdb", "create table t (a int); insert into t values (42)")
	// A tool writes into the caller's directory.
	e.must("exec", "app.pgdb", "--", "pg_dump", "-f", "dump.sql")
	b, err := os.ReadFile(e.path("dump.sql"))
	if err != nil || !bytes.Contains(b, []byte("CREATE TABLE public.t")) {
		t.Errorf("dump.sql: %v %q", err, b)
	}
	// -d picks the database.
	if got := e.query("app.pgdb", "select current_database()"); got != "app" {
		t.Errorf("default database %q", got)
	}
	out := strings.TrimSpace(e.must("exec", "app.pgdb", "-d", "postgres", "--", "psql", "-tAX", "-c", "select current_database()"))
	if out != "postgres" {
		t.Errorf("-d postgres: %q", out)
	}
	if _, _, code := e.run("exec", "app.pgdb", "--", "no-such-tool"); code != 127 {
		t.Errorf("missing tool: exit %d, want 127", code)
	}
	if _, _, code := e.run("exec", "app.pgdb", "--", "sh", "-c", "exit 7"); code != 7 {
		t.Errorf("exit status: %d, want 7", code)
	}
}

// serve starts `minipg serve` in the foreground and waits until it's ready.
func (e *env) serve(pgdb string, args ...string) (*exec.Cmd, *bytes.Buffer) {
	e.t.Helper()
	c := e.cmd("", nil, append([]string{"serve", pgdb}, args...)...)
	var out bytes.Buffer
	c.Stdout, c.Stderr = &out, &out
	if err := c.Start(); err != nil {
		e.t.Fatal(err)
	}
	e.t.Cleanup(func() {
		c.Process.Signal(syscall.SIGINT)
		c.Wait()
	})
	waitFor(e.t, "serve to be ready", 2*time.Minute, func() bool {
		return strings.Contains(out.String(), "minipg: ready")
	})
	return c, &out
}

func TestServe(t *testing.T) {
	e := newEnv(t)
	e.must("init", "app.pgdb")
	port := freePort(t)
	c, out := e.serve("app.pgdb", "-p", strconv.Itoa(port))
	st := e.status("app.pgdb")
	if !st.running || st.port != port {
		t.Errorf("status: %+v, want port %d", st, port)
	}
	// One server per .pgdb.
	if _, errs, code := e.run("serve", "app.pgdb"); code == 0 || !strings.Contains(errs, "already running") {
		t.Errorf("second serve: exit %d %q", code, errs)
	}
	// Clients use the running server.
	if got := e.query("app.pgdb", "select 7"); got != "7" {
		t.Errorf("query: %q", got)
	}
	if logs := e.must("logs", "app.pgdb"); !strings.Contains(logs, "ready on 127.0.0.1") {
		t.Errorf("logs: %q", logs)
	}
	// Ctrl-C: a clean shutdown and exit 0.
	c.Process.Signal(syscall.SIGINT)
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("serve exited: %v\n%s", err, out)
		}
	case <-time.After(45 * time.Second):
		t.Fatal("serve didn't exit after SIGINT")
	}
	if !strings.Contains(out.String(), "database system is shut down") {
		t.Errorf("no clean shutdown in the log:\n%s", out)
	}
	if e.status("app.pgdb").running {
		t.Errorf("still running")
	}
	// The log outlives the server.
	if logs := e.must("logs", "app.pgdb"); !strings.Contains(logs, "shut down") {
		t.Errorf("logs after stop: %q", logs)
	}
}

func TestPortFallback(t *testing.T) {
	e := newEnv(t)
	e.must("init", "app.pgdb")
	stored, _ := strconv.Atoi(readToml(t, e.path("app.pgdb"))["port"])
	l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", stored))
	if err != nil {
		t.Skipf("can't take port %d: %v", stored, err)
	}
	defer l.Close()
	e.query("app.pgdb", "select 1")
	st := e.status("app.pgdb")
	if st.port == stored || st.port == 0 {
		t.Errorf("port %d with %d taken", st.port, stored)
	}
	if !strings.Contains(e.url("app.pgdb"), fmt.Sprintf(":%d/", st.port)) {
		t.Errorf("url doesn't use the running port")
	}
}

func TestTrust(t *testing.T) {
	e := newEnv(t)
	e.must("init", "app.pgdb")
	if _, errs, code := e.run("serve", "app.pgdb", "--trust", "--listen", "0.0.0.0"); code == 0 || !strings.Contains(errs, "loopback") {
		t.Errorf("--trust with 0.0.0.0: exit %d %q", code, errs)
	}
	port := freePort(t)
	e.serve("app.pgdb", "--trust", "-p", strconv.Itoa(port))
	conn := e.connect(fmt.Sprintf("postgres://postgres:wrong@127.0.0.1:%d/app", port))
	conn.Close(context.Background())
}

func TestNotAPgdb(t *testing.T) {
	e := newEnv(t)
	os.Mkdir(e.path("plain"), 0o755)
	if _, errs, code := e.run("status", "plain"); code != 1 || !strings.Contains(errs, "isn't a .pgdb") {
		t.Errorf("status on a plain dir: exit %d %q", code, errs)
	}
	if _, errs, code := e.run("stop", "missing.pgdb"); code != 1 || !strings.Contains(errs, "doesn't exist") {
		t.Errorf("stop on a missing path: exit %d %q", code, errs)
	}
	// A format from the future is refused.
	e.must("init", "app.pgdb")
	toml := e.path("app.pgdb/minipg.toml")
	b, _ := os.ReadFile(toml)
	os.WriteFile(toml, bytes.Replace(b, []byte("format = 1"), []byte("format = 99"), 1), 0o600)
	if _, errs, code := e.run("app.pgdb", "select 1"); code == 0 || !strings.Contains(errs, "newer minipg") {
		t.Errorf("newer format: exit %d %q", code, errs)
	}
}

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// runJSON reads a running server's run.json.
func runJSON(t *testing.T, e *env, pgdb string) map[string]any {
	t.Helper()
	matches, _ := filepath.Glob(filepath.Join(e.dir, "run", "minipg", "*", "run.json"))
	for _, m := range matches {
		b, err := os.ReadFile(m)
		if err != nil {
			continue
		}
		var v map[string]any
		if json.Unmarshal(b, &v) == nil && strings.HasSuffix(fmt.Sprint(v["pgdb"]), pgdb) {
			return v
		}
	}
	t.Fatalf("no run.json for %s", pgdb)
	return nil
}

func TestRuntimeFiles(t *testing.T) {
	e := newEnv(t)
	e.must("init", "app.pgdb")
	e.query("app.pgdb", "select 1")
	v := runJSON(t, e, "app.pgdb")
	sock := fmt.Sprint(v["control"])
	if st, err := os.Stat(filepath.Dir(sock)); err != nil || st.Mode().Perm() != 0o700 {
		t.Errorf("runtime dir: %v %v", err, st)
	}
	if v["protocol"] != float64(1) {
		t.Errorf("protocol %v", v["protocol"])
	}
	e.must("stop", "app.pgdb")
	if _, err := os.Stat(sock); err == nil {
		t.Errorf("control socket left behind")
	}
}
