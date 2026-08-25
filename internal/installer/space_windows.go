//go:build windows

package installer

import (
	"syscall"
	"unsafe"
)

var (
	kernel32           = syscall.NewLazyDLL("kernel32.dll")
	getDiskFreeSpaceEx = kernel32.NewProc("GetDiskFreeSpaceExW")
)

// FreeBytes is how much room is left on the volume holding dir.
//
// The first figure GetDiskFreeSpaceEx returns is the space available to the
// calling user, which is what a download can actually use -- it accounts for
// any quota on the volume, where the total-free figure beside it does not.
func FreeBytes(dir string) (int64, bool) {
	path, err := syscall.UTF16PtrFromString(dir)
	if err != nil {
		return 0, false
	}
	var availableToCaller, totalBytes, totalFree uint64
	ret, _, _ := getDiskFreeSpaceEx.Call(
		uintptr(unsafe.Pointer(path)),
		uintptr(unsafe.Pointer(&availableToCaller)),
		uintptr(unsafe.Pointer(&totalBytes)),
		uintptr(unsafe.Pointer(&totalFree)),
	)
	if ret == 0 {
		return 0, false
	}
	return int64(availableToCaller), true
}
