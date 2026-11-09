//go:build !windows

package e2e

import "syscall"

// killServer kills a background server outright. It leads its own process
// group, so its guest processes on the native backend go too.
func killServer(pid int) error {
	return syscall.Kill(-pid, syscall.SIGKILL)
}
