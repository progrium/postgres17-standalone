package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/binary"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/andybalholm/brotli"
	"github.com/go-rod/rod"
	"github.com/go-rod/rod/lib/launcher"
	"github.com/gorilla/websocket"
	"github.com/hugelgupf/p9/p9"
	"github.com/progrium/go-netstack/vnet"
	xws "golang.org/x/net/websocket"
	"golang.org/x/term"
	"tractor.dev/wanix/fs"
	"tractor.dev/wanix/fs/cowfs"
	"tractor.dev/wanix/fs/localfs"
	"tractor.dev/wanix/fs/memfs"
	"tractor.dev/wanix/fs/p9kit"
	"tractor.dev/wanix/fs/tarfs"
	"tractor.dev/wanix/fs/vfs"
)

var Version string

//go:embed init index.html assets
var embedFS embed.FS

func main() {
	os.Exit(run())
}

func run() int {
	defer restoreTerminal()

	port := flag.Int("p", 5432, "host port to listen on and forward to postgres")
	debug := flag.Bool("debug", false, "show the browser and boot to a shell; Ctrl+C goes to the guest, Ctrl+D detaches")
	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), "Usage: %s [-p port] [-debug] <dataDir>\n", os.Args[0])
		flag.PrintDefaults()
	}
	flag.Parse()
	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}
	dataDir, err := filepath.Abs(flag.Arg(0))
	if err != nil {
		log.Fatal(err)
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		log.Fatal(err)
	}

	img := filepath.Join(dataDir, "pgdata.img")
	lock, err := lockImage(img)
	if err != nil {
		log.Fatal(err)
	}
	defer lock.Close()

	n, err := parseSize("10G")
	if err != nil {
		log.Fatal(err)
	}
	if err := ensureImage(img, n); err != nil {
		log.Fatal(err)
	}

	pgDB := envOr("POSTGRES_DB", "postgres")
	pgUser := envOr("POSTGRES_USER", "postgres")
	pgPassword := os.Getenv("POSTGRES_PASSWORD")
	if pgPassword == "" && !*debug {
		log.Fatal("POSTGRES_PASSWORD environment variable is required")
	}

	rootfile, err := decompressRootToCache()
	if err != nil {
		log.Fatal(err)
	}

	cfg := &vnet.Configuration{
		Debug:             false,
		MTU:               1500,
		Subnet:            "10.0.0.0/8",
		GatewayIP:         "10.0.0.1",
		GatewayMacAddress: "5a:94:ef:e4:0c:dd",
		GatewayVirtualIPs: []string{},
	}
	vn, err := vnet.New(cfg)
	if err != nil {
		log.Fatal(err)
	}

	go forwardPort(vn, fmt.Sprintf("0.0.0.0:%d", *port), "10.0.0.10:5432")

	p9l, err := vn.Listen("tcp", "10.0.0.1:3333")
	if err != nil {
		log.Fatalf("err binding: %v", err)
	}
	ctlL, err := vn.Listen("tcp", "10.0.0.1:3334")
	if err != nil {
		log.Fatalf("err binding: %v", err)
	}
	ctl := newGuestControl(ctlL)

	var ready chan bool = make(chan bool)
	go func() {

		var opts []p9.ServerOpt
		// opts = append(opts, p9.WithServerLogger(ulog.Log))

		f, err := os.Open(rootfile)
		if err != nil {
			log.Fatal(err)
		}
		defer f.Close()

		datadir, err := localfs.New(dataDir)
		if err != nil {
			log.Fatal(err)
		}

		archiveFS, err := tarfs.From(tar.NewReader(f))
		if err != nil {
			log.Fatal(err)
		}

		rwfs := memfs.New()
		rootfs := &cowfs.FS{
			Base:    archiveFS, // read-only base filesystem
			Overlay: rwfs,      // writable overlay filesystem
		}

		if err := fs.Mkdir(rwfs, "bin", 0755); err != nil {
			log.Println("error creating bin directory in memory filesystem", err)
			return
		}
		if err := fs.CopyFS(embedFS, "init", rwfs, "bin/init"); err != nil {
			log.Println("error copying init to memory filesystem", err)
			return
		}
		if err := fs.Chmod(rwfs, "bin/init", 0755); err != nil {
			log.Println("error setting permissions for init", err)
			return
		}
		// todo: fix memfs
		if err := fs.Chmod(rwfs, ".", 0755); err != nil {
			log.Println("error setting permissions for root", err)
			return
		}

		fsys := vfs.New(context.Background())
		if err := fsys.Bind(rootfs, ".", "root"); err != nil {
			log.Fatal(err)
		}
		if err := fsys.Bind(datadir, ".", "data"); err != nil {
			log.Fatal(err)
		}

		close(ready)

		// Run the server.
		s := p9.NewServer(p9kit.Attacher(fsys, p9kit.WithMemAttrStore()), opts...)
		if err := s.Serve(p9l); err != nil {
			log.Fatal(err)
		}
	}()

	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	token, err := newToken()
	if err != nil {
		log.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.Handle("/", http.FileServer(http.FS(embedFS)))
	detach := make(chan struct{})
	var detachOnce sync.Once
	mux.Handle("/tty", xws.Handler(func(c *xws.Conn) {
		handleTTY(c, *debug, func() { detachOnce.Do(func() { close(detach) }) })
	}))
	mux.Handle("/ethernet", ethernetHandler(vn))
	go func() {
		if err := http.Serve(l, requireToken(token, mux)); err != nil {
			log.Fatal(err)
		}
	}()

	sig := make(chan os.Signal, 2)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)

	<-ready
	u := launcher.New().Headless(!*debug).MustLaunch()
	browser := rod.New().ControlURL(u).MustConnect()
	defer browser.MustClose()
	query := url.Values{}
	query.Set(tokenParam, token)
	query.Set("9p", p9l.Addr().String())
	query.Set("POSTGRES_DB", pgDB)
	query.Set("POSTGRES_USER", pgUser)
	query.Set("POSTGRES_PASSWORD", pgPassword)
	if *debug {
		query.Set("debug", "1")
	}
	page := browser.MustPage(fmt.Sprintf("http://%s/?%s", l.Addr().String(), query.Encode()))
	page.MustWaitLoad()

	select {
	case rc := <-ctl.halted:
		// guest exited on its own (postgres died, or the debug shell exited)
		return rc
	case <-sig:
	case <-detach:
	}
	return shutdown(ctl, sig)
}

const shutdownTimeout = 30 * time.Second

// shutdown asks the guest to stop and waits until it reports the data
// image is unmounted and synced. A second signal forces an exit.
func shutdown(ctl *guestControl, sig <-chan os.Signal) int {
	restoreTerminal()
	fmt.Fprintln(os.Stderr, "\nShutting down... (Ctrl+C again to force)")

	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	go func() {
		if err := ctl.stop(ctx); err != nil && ctx.Err() == nil {
			log.Println("stopping guest:", err)
		}
	}()

	select {
	case <-ctl.halted:
		return 0
	case <-sig:
		fmt.Fprintln(os.Stderr, "Forced exit; data image may need recovery on next start")
	case <-ctx.Done():
		fmt.Fprintln(os.Stderr, "Timed out waiting for guest to shut down")
	}
	return 1
}

// guestControl is the host end of init's control connection. The host
// sends "stop" to request a clean shutdown; init replies "halted <rc>"
// once the data image is unmounted and synced, right before poweroff.
type guestControl struct {
	mu        sync.Mutex
	conn      net.Conn
	connected chan struct{}
	halted    chan int
}

func newGuestControl(l net.Listener) *guestControl {
	g := &guestControl{connected: make(chan struct{}), halted: make(chan int, 1)}
	go g.serve(l)
	return g
}

func (g *guestControl) serve(l net.Listener) {
	for {
		conn, err := l.Accept()
		if err != nil {
			log.Println(err)
			return
		}
		g.mu.Lock()
		first := g.conn == nil
		g.conn = conn
		g.mu.Unlock()
		if first {
			close(g.connected)
		}
		go g.read(conn)
	}
}

func (g *guestControl) read(conn net.Conn) {
	sc := bufio.NewScanner(conn)
	for sc.Scan() {
		var rc int
		if _, err := fmt.Sscanf(sc.Text(), "halted %d", &rc); err == nil {
			// closing lets init's nc exit, telling init the message landed
			conn.Close()
			select {
			case g.halted <- rc:
			default:
			}
			return
		}
	}
}

// stop waits for the guest to connect (it may still be booting), then
// sends the stop request.
func (g *guestControl) stop(ctx context.Context) error {
	select {
	case <-g.connected:
	case <-ctx.Done():
		return ctx.Err()
	}
	g.mu.Lock()
	conn := g.conn
	g.mu.Unlock()
	_, err := io.WriteString(conn, "stop\n")
	return err
}

var rawTerm struct {
	sync.Mutex
	fd    int
	state *term.State
}

func makeRaw(fd int) error {
	rawTerm.Lock()
	defer rawTerm.Unlock()
	state, err := term.MakeRaw(fd)
	if err != nil {
		return err
	}
	rawTerm.fd, rawTerm.state = fd, state
	return nil
}

func restoreTerminal() {
	rawTerm.Lock()
	defer rawTerm.Unlock()
	if rawTerm.state != nil {
		term.Restore(rawTerm.fd, rawTerm.state)
		rawTerm.state = nil
	}
}

const (
	tokenParam  = "token"
	tokenCookie = "pg17s_token"
)

func newToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// requireToken rejects requests that don't carry token, so other local
// processes can't reach the tty or ethernet relay on the loopback port.
// The browser gets it as a query param on the initial page load and is
// handed a cookie so subresource and websocket requests are covered too.
func requireToken(token string, next http.Handler) http.Handler {
	valid := func(s string) bool {
		return subtle.ConstantTimeCompare([]byte(s), []byte(token)) == 1
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if c, err := r.Cookie(tokenCookie); err == nil && valid(c.Value) {
			next.ServeHTTP(w, r)
			return
		}
		if valid(r.URL.Query().Get(tokenParam)) {
			http.SetCookie(w, &http.Cookie{
				Name:     tokenCookie,
				Value:    token,
				Path:     "/",
				HttpOnly: true,
				SameSite: http.SameSiteStrictMode,
			})
			next.ServeHTTP(w, r)
			return
		}
		http.Error(w, "forbidden", http.StatusForbidden)
	})
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func forwardPort(vn *vnet.VirtualNetwork, localAddr, remoteAddr string) {
	// listen on localPort and forward traffic to remotePort through the virtual network
	listener, err := net.Listen("tcp", localAddr)
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()

	fmt.Printf("Forwarding traffic from %s to browser container %s\n", localAddr, remoteAddr)
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Println(err)
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			remoteConn, err := vn.Dial("tcp", remoteAddr)
			if err != nil {
				log.Println(err)
				return
			}
			defer remoteConn.Close()
			go func() {
				_, _ = io.Copy(remoteConn, c)
			}()
			_, _ = io.Copy(c, remoteConn)
		}(conn)
	}
}

func ethernetHandler(vn *vnet.VirtualNetwork) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if vn == nil {
			http.Error(w, "ethernet not available", http.StatusNotFound)
			return
		}
		if !websocket.IsWebSocketUpgrade(r) {
			http.Error(w, "expecting websocket upgrade", http.StatusBadRequest)
			return
		}

		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			log.Println(err)
			return
		}
		defer ws.Close()

		// log.Println("ethernet session started")

		if err := vn.AcceptQemu(r.Context(), &qemuAdapter{Conn: ws}); err != nil {
			if strings.Contains(err.Error(), "websocket: close") {
				return
			}
			log.Println(err)
			return
		}
	})
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}

// qemuAdapter wraps a websocket connection and converts
// messages to qemu length prefixed protocol and back
type qemuAdapter struct {
	*websocket.Conn
	mu          sync.Mutex
	readBuffer  []byte
	writeBuffer []byte
	readOffset  int
}

func (q *qemuAdapter) Read(p []byte) (n int, err error) {
	if len(q.readBuffer) == 0 {
		_, message, err := q.ReadMessage()
		if err != nil {
			return 0, err
		}
		length := uint32(len(message))
		lengthPrefix := make([]byte, 4)
		binary.BigEndian.PutUint32(lengthPrefix, length)
		q.readBuffer = append(lengthPrefix, message...)
		q.readOffset = 0
	}

	n = copy(p, q.readBuffer[q.readOffset:])
	q.readOffset += n
	if q.readOffset >= len(q.readBuffer) {
		q.readBuffer = nil
	}
	return n, nil
}

func (q *qemuAdapter) Write(p []byte) (int, error) {
	q.mu.Lock()
	defer q.mu.Unlock()

	q.writeBuffer = append(q.writeBuffer, p...)

	if len(q.writeBuffer) < 4 {
		return len(p), nil
	}

	length := binary.BigEndian.Uint32(q.writeBuffer[:4])
	if len(q.writeBuffer) < int(length)+4 {
		return len(p), nil
	}

	err := q.WriteMessage(websocket.BinaryMessage, q.writeBuffer[4:4+length])
	if err != nil {
		return 0, err
	}

	q.writeBuffer = q.writeBuffer[4+length:]
	return len(p), nil
}

func (c *qemuAdapter) LocalAddr() net.Addr {
	return &net.UnixAddr{}
}

func (c *qemuAdapter) RemoteAddr() net.Addr {
	return &net.UnixAddr{}
}

func (c *qemuAdapter) SetDeadline(t time.Time) error {
	return nil
}
func (c *qemuAdapter) SetReadDeadline(t time.Time) error {
	return nil
}
func (c *qemuAdapter) SetWriteDeadline(t time.Time) error {
	return nil
}

// handleTTY streams the guest console to stdout. Only in debug mode on a
// real terminal is stdin forwarded in raw mode (so Ctrl+C reaches the
// guest); there Ctrl+D detaches. Otherwise Ctrl+C is a normal signal.
func handleTTY(ch *xws.Conn, debug bool, detach func()) {
	ch.PayloadType = xws.BinaryFrame

	done := make(chan struct{})
	go func() {
		io.Copy(os.Stdout, ch)
		close(done)
	}()

	fd := int(os.Stdin.Fd())
	if !debug || !term.IsTerminal(fd) {
		<-done
		return
	}
	if err := makeRaw(fd); err != nil {
		log.Println(err)
		<-done
		return
	}

	// resize messages go as text frames; console bytes stay binary
	sendSize := func() {
		cols, rows, err := term.GetSize(int(os.Stdout.Fd()))
		if err != nil {
			return
		}
		if err := xws.JSON.Send(ch, [2]int{rows, cols}); err != nil {
			log.Println(err)
		}
	}
	sendSize()
	go watchResize(sendSize)

	buffer := make([]byte, 1024)
	for {
		n, err := os.Stdin.Read(buffer)
		if err != nil {
			break
		}
		// Ctrl+D (EOT) detaches
		if i := bytes.IndexByte(buffer[:n], 4); i >= 0 {
			if i > 0 {
				ch.Write(buffer[:i])
			}
			break
		}
		if _, err := ch.Write(buffer[:n]); err != nil {
			log.Println(err)
		}
	}
	detach()
	// keep showing guest output while it shuts down
	<-done
}

// decompressRootToCache decompresses a .br file into <user cache dir>/<app>/
// and returns the path of the decompressed file.
func decompressRootToCache() (string, error) {
	cacheDir, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(cacheDir, "postgres17-standalone")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	cachedRoot := filepath.Join(dir, "root.tar")
	if _, err := os.Stat(cachedRoot); err == nil {
		return cachedRoot, nil
	}

	fmt.Println("Decompressing root image to cache...")

	src, err := embedFS.Open("assets/root.tar.br")
	if err != nil {
		return "", err
	}
	defer src.Close()

	// Write to a temp file, then rename, so a failed run never leaves a partial file.
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name()) // no-op after a successful rename

	if _, err := io.Copy(tmp, brotli.NewReader(src)); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	return cachedRoot, os.Rename(tmp.Name(), cachedRoot)
}

// ensureImage creates path as a sparse file of the given size.
// An existing non-empty image is left untouched; ext4 inside it
// can't grow without resize2fs, so a larger size is ignored.
// Call it only while holding the lock from lockImage.
func ensureImage(path string, size int64) error {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		return err
	}
	if fi.Size() > 0 {
		return nil // existing image
	}

	// New (or left empty by an earlier failed run): mark sparse, then extend.
	if err := makeSparse(f); err != nil {
		return fmt.Errorf("marking %s sparse: %w", path, err)
	}
	if err := f.Truncate(size); err != nil {
		return err
	}
	return f.Sync()
}

// parseSize accepts plain bytes or a K/M/G/T suffix: "32G", "512M".
func parseSize(s string) (int64, error) {
	s = strings.ToUpper(strings.TrimSpace(s))
	mult := int64(1)
	for suffix, m := range map[string]int64{"K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40} {
		if strings.HasSuffix(s, suffix) {
			mult, s = m, strings.TrimSuffix(s, suffix)
			break
		}
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("invalid size %q", s)
	}
	return n * mult, nil
}
