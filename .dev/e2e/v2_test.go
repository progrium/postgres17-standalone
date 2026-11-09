package e2e

// Iteration 2: background-server lifetime, host commands, dumps, database
// admin, password rotation, crash recovery and fetching other majors.

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestIdleTimeout(t *testing.T) {
	e := newEnv(t)
	e.must("init", "app.pgdb")
	if _, errs, code := e.runWith("", []string{"MINIPG_IDLE=2"}, "app.pgdb", "select 1"); code != 0 {
		t.Fatalf("query: %s", errs)
	}
	if !e.status("app.pgdb").running {
		t.Fatal("no background server after a query")
	}
	waitFor(t, "the idle server to stop", 30*time.Second, func() bool { return !e.status("app.pgdb").running })
	// The next command starts a new one.
	if got := e.query("app.pgdb", "select 2"); got != "2" {
		t.Errorf("query after idle stop: %q", got)
	}
}

func TestEnvAndRun(t *testing.T) {
	e := newEnv(t)
	e.must("init", "app.pgdb")
	out := e.must("env", "app.pgdb")
	if !strings.Contains(out, "export DATABASE_URL='postgres://") || !strings.Contains(out, "export PGDATABASE='app'") {
		t.Errorf("env: %q", out)
	}
	url := e.url("app.pgdb")
	got := e.must("run", "app.pgdb", "--", "sh", "-c", `echo "$DATABASE_URL|$PGDATABASE|$PWD"`)
	want := url + "|app|" + e.dir
	if strings.TrimSpace(got) != want {
		t.Errorf("run: %q, want %q", got, want)
	}
	if _, _, code := e.run("run", "app.pgdb", "--", "sh", "-c", "exit 7"); code != 7 {
		t.Errorf("run's exit code: %d, want 7", code)
	}
	e.must("stop", "app.pgdb")

	// A running command holds the server open past the idle timeout, even
	// without connections.
	c := e.cmd("", []string{"MINIPG_IDLE=1"}, "run", "app.pgdb", "--", "sleep", "6")
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(4 * time.Second)
	if !e.status("app.pgdb").running {
		t.Errorf("server stopped while run held it")
	}
	if err := c.Wait(); err != nil {
		t.Fatalf("run: %v", err)
	}
	waitFor(t, "the server to stop after run", 30*time.Second, func() bool { return !e.status("app.pgdb").running })
}

func TestDumpRestore(t *testing.T) {
	e := newEnv(t)
	e.must("init", "app.pgdb")
	e.query("app.pgdb", "create table t (id int primary key, s text); insert into t select g, md5(g::text) from generate_series(1, 500) g")
	sql := e.must("dump", "app.pgdb")
	if !strings.Contains(sql, "CREATE TABLE public.t") {
		t.Fatalf("dump: %.300q", sql)
	}
	os.WriteFile(e.path("d.sql"), []byte(sql), 0o644)
	// Custom format, written by pg_dump into the working directory.
	e.must("exec", "app.pgdb", "--", "pg_dump", "-Fc", "-f", "d.dump")
	custom, err := os.ReadFile(e.path("d.dump"))
	if err != nil || !strings.HasPrefix(string(custom), "PGDMP") {
		t.Fatalf("custom dump: %v", err)
	}

	for _, c := range []struct {
		db, stdin string
		args      []string
	}{
		{"sqlfile", "", []string{"d.sql"}},
		{"sqlstdin", sql, nil},
		{"customfile", "", []string{"d.dump"}},
		{"customstdin", string(custom), nil},
	} {
		e.must("create", "app.pgdb", c.db)
		args := append([]string{"restore", "app.pgdb", "-d", c.db}, c.args...)
		if out, errs, code := e.runWith(c.stdin, nil, args...); code != 0 {
			t.Errorf("%s: exit %d\n%s%s", c.db, code, out, errs)
			continue
		}
		e.must("default", "app.pgdb", c.db)
		if got := e.query("app.pgdb", "select count(*) from t"); got != "500" {
			t.Errorf("%s: %q rows, want 500", c.db, got)
		}
	}
	// A failing statement fails the restore.
	if _, _, code := e.runWith("select * from nope;", nil, "restore", "app.pgdb"); code == 0 {
		t.Errorf("a bad restore exited 0")
	}
}

func TestDatabases(t *testing.T) {
	e := newEnv(t)
	e.must("init", "app.pgdb")
	e.must("create", "app.pgdb", "other")
	out := e.must("dbs", "app.pgdb")
	if !strings.Contains(out, "* app") || !strings.Contains(out, "  other") {
		t.Errorf("dbs: %q", out)
	}
	if got := strings.TrimSpace(e.must("default", "app.pgdb")); got != "app" {
		t.Errorf("default: %q", got)
	}
	e.must("default", "app.pgdb", "other")
	if got := e.query("app.pgdb", "select current_database()"); got != "other" {
		t.Errorf("after default: %q", got)
	}
	if readToml(t, e.path("app.pgdb"))["database"] != "other" {
		t.Errorf("default not saved")
	}
	if !strings.HasSuffix(e.url("app.pgdb"), "/other") {
		t.Errorf("url doesn't follow the default")
	}
	if _, errs, code := e.run("drop", "app.pgdb", "other"); code == 0 || !strings.Contains(errs, "default") {
		t.Errorf("dropping the default: exit %d %q", code, errs)
	}
	if _, _, code := e.run("default", "app.pgdb", "missing"); code == 0 {
		t.Errorf("default to a missing database succeeded")
	}
	e.must("default", "app.pgdb", "app")
	e.must("drop", "app.pgdb", "other")
	if out := e.must("dbs", "app.pgdb"); strings.Contains(out, "other") {
		t.Errorf("dbs after drop: %q", out)
	}
	// -d picks a database for one command.
	e.must("create", "app.pgdb", "x")
	if got := strings.TrimSpace(e.must("exec", "app.pgdb", "-d", "x", "--", "psql", "-tAXc", "select current_database()")); got != "x" {
		t.Errorf("exec -d: %q", got)
	}
}

func TestPasswd(t *testing.T) {
	e := newEnv(t)
	e.must("init", "app.pgdb")
	e.query("app.pgdb", "select 1")
	old := e.url("app.pgdb")
	e.connect(old).Close(context.Background())
	e.must("passwd", "app.pgdb")
	fresh := e.url("app.pgdb")
	if fresh == old {
		t.Fatal("url unchanged after passwd")
	}
	if c, err := connectErr(old); err == nil {
		c.Close(context.Background())
		t.Errorf("the old password still works")
	}
	e.connect(fresh).Close(context.Background())
	// The server keeps working with the new password: status counts
	// clients, and a restart uses it.
	if st := e.status("app.pgdb"); !st.running || st.clients < 0 {
		t.Errorf("status after passwd: %+v", st)
	}
	e.must("stop", "app.pgdb")
	if got := e.query("app.pgdb", "select 3"); got != "3" {
		t.Errorf("query after restart: %q", got)
	}
}

func TestCrashRecovery(t *testing.T) {
	e := newEnv(t)
	e.must("init", "app.pgdb")
	e.query("app.pgdb", "create extension amcheck; create table t (id int primary key, s text); insert into t select g, repeat('x', 200) from generate_series(1, 20000) g")
	pid := int(runJSON(t, e, "app.pgdb")["pid"].(float64))
	// The background server leads its own process group.
	if err := syscall.Kill(-pid, syscall.SIGKILL); err != nil {
		t.Fatalf("kill: %v", err)
	}
	waitFor(t, "the lock to be released", 15*time.Second, func() bool { return !e.status("app.pgdb").running })
	if got := e.query("app.pgdb", "select count(*) from t"); got != "20000" {
		t.Errorf("rows after crash: %q", got)
	}
	if got := e.query("app.pgdb", "select bt_index_check('t_pkey', true)"); got != "" {
		t.Errorf("amcheck: %q", got)
	}
	if logs := e.must("logs", "app.pgdb"); !strings.Contains(logs, "not properly shut down") {
		t.Logf("no recovery message in the log:\n%s", logs)
	}
}

// TestFetch downloads Postgres 17 from Docker Hub, so it runs only with
// MINIPG_E2E_NET=1.
func TestFetch(t *testing.T) {
	if os.Getenv("MINIPG_E2E_NET") != "1" {
		t.Skip("MINIPG_E2E_NET=1 runs it (downloads from Docker Hub)")
	}
	e := newEnv(t)
	// Its own cache, so prune doesn't touch the shared one.
	cache := e.path("cache")
	os.MkdirAll(cache, 0o700)
	e.vars = append(e.vars, "XDG_CACHE_HOME="+cache)
	if _, errs, code := e.runWith("", []string{"MINIPG_OFFLINE=1"}, "init", "off.pgdb", "--pg", "17"); code == 0 || !strings.Contains(errs, "offline") {
		t.Errorf("offline init: exit %d %q", code, errs)
	}
	if _, err := os.Stat(e.path("off.pgdb")); err == nil {
		t.Errorf("a failed init left off.pgdb")
	}
	e.must("fetch", "17")
	if out := e.must("versions"); !strings.Contains(out, "cached    17.") {
		t.Errorf("versions: %q", out)
	}
	e.must("init", "p17.pgdb", "--pg", "17")
	if got := e.query("p17.pgdb", "show server_version"); !strings.HasPrefix(got, "17.") {
		t.Errorf("server_version %q", got)
	}
	e.must("stop", "p17.pgdb")
	e.must("prune")
	if out := e.must("versions"); strings.Contains(out, "cached") {
		t.Errorf("versions after prune: %q", out)
	}
	// Opening it again downloads the root on demand.
	if got := e.query("p17.pgdb", "select 1"); got != "1" {
		t.Errorf("query after prune: %q", got)
	}
	matches, _ := filepath.Glob(filepath.Join(cache, "minipg", "roots", "sha256-*.json"))
	if len(matches) < 2 {
		t.Errorf("roots after reopening: %v", matches)
	}
}

func connectErr(url string) (*pgx.Conn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return pgx.Connect(ctx, url)
}
