//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"golang.org/x/sys/unix"
)

// lockImage takes an exclusive, non-blocking lock on path+".lock".
// Keep the returned file open for the life of the process; the OS
// releases the lock automatically if the process dies.
func lockImage(path string) (*os.File, error) {
	f, err := os.OpenFile(path+".lock", os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("%s is in use by another instance", path)
	}
	return f, nil
}

// APFS, ext4, XFS and btrfs make extended regions sparse automatically.
func makeSparse(*os.File) error { return nil }

func watchResize(fn func()) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGWINCH)
	for range ch {
		fn()
	}
}
