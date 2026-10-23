package main

import (
	"archive/tar"
	"context"
	"embed"
	"encoding/binary"
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
	port := flag.Int("p", 5432, "host port to listen on and forward to postgres")
	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), "Usage: %s [-p port] <dataDir>\n", os.Args[0])
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

	pgDB := envOr("POSTGRES_DB", "postgres")
	pgUser := envOr("POSTGRES_USER", "postgres")
	pgPassword := os.Getenv("POSTGRES_PASSWORD")
	if pgPassword == "" {
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
	http.Handle("/", http.FileServer(http.FS(embedFS)))
	http.Handle("/tty", xws.Handler(handleTTY))
	http.Handle("/ethernet", ethernetHandler(vn))
	go func() {
		if err := http.Serve(l, nil); err != nil {
			log.Fatal(err)
		}
	}()

	<-ready
	u := launcher.New().Headless(true).MustLaunch()
	browser := rod.New().ControlURL(u).MustConnect()
	defer browser.MustClose()
	query := url.Values{}
	query.Set("9p", p9l.Addr().String())
	query.Set("POSTGRES_DB", pgDB)
	query.Set("POSTGRES_USER", pgUser)
	query.Set("POSTGRES_PASSWORD", pgPassword)
	page := browser.MustPage(fmt.Sprintf("http://%s/?%s", l.Addr().String(), query.Encode()))
	page.MustWaitLoad()

	// Keep the page open until interrupted.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig

	fmt.Println("\nShutting down...")
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

func handleTTY(ch *xws.Conn) {
	ch.PayloadType = xws.BinaryFrame
	oldstate, err := term.MakeRaw(int(os.Stdin.Fd()))
	if err != nil {
		log.Fatal(err)
	}

	go io.Copy(os.Stdout, ch)

	buffer := make([]byte, 1024)
	for {
		n, err := os.Stdin.Read(buffer)
		if err != nil {
			term.Restore(int(os.Stdin.Fd()), oldstate)
			log.Fatal("Error reading from stdin:", err)
		}

		for i := 0; i < n; i++ {
			// Check for Ctrl-D (ASCII 4)
			if buffer[i] == 4 {
				term.Restore(int(os.Stdin.Fd()), oldstate)
				ch.Close()
				os.Exit(0) // Exit the program on Ctrl-D
				return
			}
		}

		_, err = ch.Write(buffer[:n])
		if err != nil {
			log.Println(err)
		}
	}
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
