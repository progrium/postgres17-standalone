package main

import (
	"fmt"
	"os"

	"golang.org/x/sys/windows"
)

// Windows has no SIGWINCH; only the initial size is sent.
func watchResize(fn func()) {}

const fsctlSetSparse = 0x000900C4 // CTL_CODE(FILE_DEVICE_FILE_SYSTEM, 49, METHOD_BUFFERED, FILE_SPECIAL_ACCESS)

func lockImage(path string) (*os.File, error) {
	f, err := os.OpenFile(path+".lock", os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	err = windows.LockFileEx(windows.Handle(f.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
		0, 1, 0, new(windows.Overlapped))
	if err != nil {
		f.Close()
		return nil, fmt.Errorf("%s is in use by another instance", path)
	}
	return f, nil
}

// Without this, NTFS reserves the full size on Truncate.
func makeSparse(f *os.File) error {
	var n uint32
	return windows.DeviceIoControl(windows.Handle(f.Fd()), fsctlSetSparse,
		nil, 0, nil, 0, &n, nil)
}
