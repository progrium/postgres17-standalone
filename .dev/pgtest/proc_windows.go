package main

import (
	"os/exec"
	"syscall"
)

var (
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	user32   = syscall.NewLazyDLL("user32.dll")
)

// prepareConsole gives this process a (hidden) console for the server to
// inherit, since console control events only reach processes sharing one.
// winrun starts us without a console.
func prepareConsole() {
	if h, _, _ := kernel32.NewProc("GetConsoleWindow").Call(); h != 0 {
		return
	}
	_, _, _ = kernel32.NewProc("AllocConsole").Call()
	if h, _, _ := kernel32.NewProc("GetConsoleWindow").Call(); h != 0 {
		_, _, _ = user32.NewProc("ShowWindow").Call(h, 0)
	}
}

// setProcAttr puts the server in its own process group so a Ctrl+Break can be
// sent to it alone.
func setProcAttr(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
}

// interrupt sends Ctrl+Break, which Go delivers as os.Interrupt.
func interrupt(cmd *exec.Cmd) error {
	r, _, err := kernel32.NewProc("GenerateConsoleCtrlEvent").Call(syscall.CTRL_BREAK_EVENT, uintptr(cmd.Process.Pid))
	if r == 0 {
		return err
	}
	return nil
}
