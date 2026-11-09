//go:build windows

package e2e

import "os"

// killServer kills a background server outright.
func killServer(pid int) error {
	p, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return p.Kill()
}
