//go:build linux

package main

import (
	"fmt"
	"net"
	"syscall"
	"unsafe"
)

// soOriginalDst is the SOL_IP getsockopt that returns a redirected socket's
// pre-DNAT destination — the address the client originally dialed before the
// container's iptables REDIRECT/TPROXY rule sent it here. This is how the proxy
// recovers the real upstream in transparent mode without the client knowing a
// proxy exists.
const soOriginalDst = 80

// originalDst reads the original (pre-redirect) IPv4 destination of c.
func originalDst(c *net.TCPConn) (string, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return "", err
	}
	var addr string
	var sockErr error
	ctrlErr := raw.Control(func(fd uintptr) {
		var sa syscall.RawSockaddrInet4
		sz := uint32(unsafe.Sizeof(sa))
		_, _, errno := syscall.Syscall6(
			syscall.SYS_GETSOCKOPT,
			fd,
			uintptr(syscall.SOL_IP),
			uintptr(soOriginalDst),
			uintptr(unsafe.Pointer(&sa)),
			uintptr(unsafe.Pointer(&sz)),
			0,
		)
		if errno != 0 {
			sockErr = fmt.Errorf("getsockopt SO_ORIGINAL_DST: %w", errno)
			return
		}
		ip := net.IPv4(sa.Addr[0], sa.Addr[1], sa.Addr[2], sa.Addr[3])
		// sa.Port is network byte order (big-endian); convert to host order.
		port := int(sa.Port&0xff)<<8 | int(sa.Port>>8)
		addr = net.JoinHostPort(ip.String(), fmt.Sprintf("%d", port))
	})
	if ctrlErr != nil {
		return "", ctrlErr
	}
	return addr, sockErr
}
