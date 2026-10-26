// pgtest runs end-to-end tests of postgres17-standalone in a guest for
// .dev/test.sh. It expects the binary next to it and exits non-zero if any
// test fails.
package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

const password = "secret"

var (
	port     = flag.Int("p", 15432, "host port for postgres")
	bootWait = flag.Duration("boot", 10*time.Minute, "how long to wait for postgres to accept connections")
	stopWait = flag.Duration("stop", 90*time.Second, "how long to wait for a clean shutdown")

	bin       string
	pass, bad int
)

func main() {
	flag.Parse()
	exe, err := os.Executable()
	if err != nil {
		fatal(err)
	}
	bin = filepath.Join(filepath.Dir(exe), "postgres17-standalone")
	if runtime.GOOS == "windows" {
		bin += ".exe"
	}
	prepareConsole()

	data, err := os.MkdirTemp(filepath.Dir(exe), "data-")
	if err != nil {
		fatal(err)
	}
	defer os.RemoveAll(data)

	testCLI(data)
	testServer(data)

	fmt.Printf("  %d passed, %d failed\n", pass, bad)
	if bad > 0 {
		os.Exit(1)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "pgtest:", err)
	os.Exit(1)
}

func ok(name string) { fmt.Println("  ok  ", name); pass++ }

func fail(name string, format string, args ...any) {
	fmt.Printf("  FAIL %s: %s\n", name, fmt.Sprintf(format, args...))
	bad++
}

func failOut(name, out string, format string, args ...any) {
	fail(name, format, args...)
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) > 30 {
		lines = lines[len(lines)-30:]
	}
	for _, l := range lines {
		fmt.Println("       out|", strings.TrimRight(l, "\r"))
	}
}

// proc is a running postgres17-standalone with its combined output captured.
type proc struct {
	cmd  *exec.Cmd
	mu   sync.Mutex
	out  bytes.Buffer
	done chan struct{}
	err  error
}

func (p *proc) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.out.Write(b)
}

func (p *proc) output() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.out.String()
}

func start(env []string, args ...string) (*proc, error) {
	p := &proc{done: make(chan struct{})}
	p.cmd = exec.Command(bin, args...)
	p.cmd.Env = append(os.Environ(), env...)
	p.cmd.Stdout, p.cmd.Stderr = p, p
	setProcAttr(p.cmd)
	if err := p.cmd.Start(); err != nil {
		return nil, err
	}
	go func() {
		p.err = p.cmd.Wait()
		close(p.done)
	}()
	return p, nil
}

// wait waits up to d for the process to exit and returns its exit code, or
// -1 on timeout.
func (p *proc) wait(d time.Duration) int {
	select {
	case <-p.done:
	case <-time.After(d):
		return -1
	}
	var ee *exec.ExitError
	if errors.As(p.err, &ee) {
		return ee.ExitCode()
	}
	if p.err != nil {
		return -2
	}
	return 0
}

func (p *proc) kill() {
	_ = p.cmd.Process.Kill()
	<-p.done
}

// run runs the binary to completion and returns its exit code and output.
func run(env []string, args ...string) (int, string) {
	p, err := start(env, args...)
	if err != nil {
		return -2, err.Error()
	}
	code := p.wait(time.Minute)
	if code == -1 {
		p.kill()
	}
	return code, p.output()
}

func testCLI(data string) {
	if code, out := run(nil, "-v"); code != 0 || strings.TrimSpace(out) != "dev" {
		failOut("version", out, "exit %d", code)
	} else {
		ok("version")
	}
	if code, out := run(nil); code != 2 || !strings.Contains(out, "Usage:") {
		failOut("usage without dataDir", out, "exit %d, want 2", code)
	} else {
		ok("usage without dataDir")
	}
	if code, out := run([]string{"POSTGRES_PASSWORD="}, data); code == 0 || !strings.Contains(out, "POSTGRES_PASSWORD") {
		failOut("requires POSTGRES_PASSWORD", out, "exit %d", code)
	} else {
		ok("requires POSTGRES_PASSWORD")
	}
}

func connect(ctx context.Context) (*pgx.Conn, error) {
	url := fmt.Sprintf("postgres://postgres:%s@127.0.0.1:%d/postgres?sslmode=disable&connect_timeout=10", password, *port)
	return pgx.Connect(ctx, url)
}

// boot starts the server on data and waits for postgres to answer a query.
func boot(name, data string) (*proc, *pgx.Conn) {
	p, err := start([]string{"POSTGRES_PASSWORD=" + password}, "-p", fmt.Sprint(*port), data)
	if err != nil {
		fail(name, "start: %v", err)
		return nil, nil
	}
	began := time.Now()
	deadline := began.Add(*bootWait)
	for time.Now().Before(deadline) {
		select {
		case <-p.done:
			failOut(name, p.output(), "exited early with %v", p.err)
			return nil, nil
		default:
		}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		conn, err := connect(ctx)
		if err == nil {
			err = conn.Ping(ctx)
			if err == nil {
				cancel()
				ok(fmt.Sprintf("%s (%s)", name, time.Since(began).Round(time.Second)))
				return p, conn
			}
			conn.Close(context.Background())
		}
		cancel()
		time.Sleep(2 * time.Second)
	}
	failOut(name, p.output(), "no connection after %s", *bootWait)
	p.kill()
	return nil, nil
}

// stop interrupts the server and checks that the guest shuts down cleanly.
func stop(name string, p *proc, conn *pgx.Conn) {
	if conn != nil {
		conn.Close(context.Background())
	}
	if err := interrupt(p.cmd); err != nil {
		fail(name, "interrupt: %v", err)
		p.kill()
		return
	}
	code := p.wait(*stopWait)
	if code == -1 {
		p.kill()
	}
	if code != 0 || !strings.Contains(p.output(), "Shutting down") {
		failOut(name, p.output(), "exit %d, want 0", code)
		return
	}
	ok(name)
}

func query(name string, conn *pgx.Conn, sql string, want string) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	var got string
	if err := conn.QueryRow(ctx, sql).Scan(&got); err != nil {
		fail(name, "%v", err)
		return
	}
	if !strings.Contains(got, want) {
		fail(name, "got %q, want %q", got, want)
		return
	}
	ok(name)
}

func exec_(name string, conn *pgx.Conn, sql string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	if _, err := conn.Exec(ctx, sql); err != nil {
		fail(name, "%v", err)
		return false
	}
	ok(name)
	return true
}

func testServer(data string) {
	p, conn := boot("first boot", data)
	if p == nil {
		return
	}
	query("server version", conn, "show server_version", "17.")
	exec_("write data", conn, "create table t (v text); insert into t values ('persisted')")

	code, out := run([]string{"POSTGRES_PASSWORD=" + password}, "-p", fmt.Sprint(*port+1), data)
	if code == 0 || !strings.Contains(out, "in use by another instance") {
		failOut("data dir lock", out, "exit %d", code)
	} else {
		ok("data dir lock")
	}

	stop("clean shutdown", p, conn)

	if _, err := os.Stat(filepath.Join(data, "pgdata.img")); err != nil {
		fail("data image", "%v", err)
	} else {
		ok("data image")
	}

	p, conn = boot("second boot", data)
	if p == nil {
		return
	}
	query("data persisted", conn, "select v from t", "persisted")
	stop("clean shutdown again", p, conn)
}
