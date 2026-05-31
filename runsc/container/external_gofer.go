// Copyright 2026 The gVisor Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package container

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"

	specs "github.com/opencontainers/runtime-spec/specs-go"
	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/log"
	"gvisor.dev/gvisor/runsc/boot"
	"gvisor.dev/gvisor/runsc/cmd/sandboxsetup"
	"gvisor.dev/gvisor/runsc/config"
	"gvisor.dev/gvisor/runsc/sandbox"
	"gvisor.dev/gvisor/runsc/specutils"
)

// createExternalGoferProcess starts an out-of-process gofer binary (see
// --gofer-binary) instead of `runsc gofer`. The external binary receives the
// LISAFS socket to the sentry on file descriptor 3 and is expected to proxy
// the protocol (e.g. to cortex-fuse over a host UDS).
func (c *Container) createExternalGoferProcess(conf *config.Config, mountHints *boot.PodMountHints, attached bool) ([]*os.File, []*os.File, *os.File, *os.File, error) {
	if shouldCreateDeviceGofer(c.Spec, conf) {
		return nil, nil, nil, nil, fmt.Errorf("gofer-binary is incompatible with GPU/TPU workloads that require a device gofer")
	}
	if !c.GoferMountConfs[0].ShouldUseLisafs() {
		return nil, nil, nil, nil, fmt.Errorf("gofer-binary requires a LISAFS-backed root mount")
	}
	if lisafsMountCount(c.GoferMountConfs) != 1 {
		return nil, nil, nil, nil, fmt.Errorf("gofer-binary supports exactly one LISAFS-backed mount (the root); got %d", lisafsMountCount(c.GoferMountConfs))
	}

	if err := sandbox.SetCloExeOnAllFDs(); err != nil {
		return nil, nil, nil, nil, fmt.Errorf("setting CLOEXEC on all FDs: %w", err)
	}

	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	sandEnd := os.NewFile(uintptr(fds[0]), "sandbox IO FD")
	goferEnd := os.NewFile(uintptr(fds[1]), "external gofer IO FD")

	mountsSand, mountsGofer, err := os.Pipe()
	if err != nil {
		sandEnd.Close()
		goferEnd.Close()
		return nil, nil, nil, nil, err
	}

	cmd := exec.Command(conf.GoferBinary)
	cmd.Args = []string{filepath.Base(conf.GoferBinary)}
	cmd.Env = slices.DeleteFunc(os.Environ(), func(env string) bool { return strings.HasPrefix(env, "GOMAXPROCS=") })
	cmd.ExtraFiles = []*os.File{goferEnd}
	cmd.SysProcAttr = &unix.SysProcAttr{Setsid: true}
	if attached {
		cmd.SysProcAttr.Pdeathsig = unix.SIGKILL
	}

	nss := []specs.LinuxNamespace{
		{Type: specs.IPCNamespace},
		{Type: specs.MountNamespace},
		{Type: specs.NetworkNamespace},
		{Type: specs.PIDNamespace},
		{Type: specs.UTSNamespace},
	}

	rootlessEUID := unix.Geteuid() != 0
	setUserMappings := false
	if !rootlessEUID {
		if userNS, ok := specutils.GetNS(specs.UserNamespace, c.Spec); ok {
			nss = append(nss, userNS)
			specutils.SetUIDGIDMappings(cmd, c.Spec)
			cmd.SysProcAttr.Credential = &syscall.Credential{Uid: 0, Gid: 0}
		}
	} else {
		userNS, ok := specutils.GetNS(specs.UserNamespace, c.Spec)
		if !ok {
			goferEnd.Close()
			sandEnd.Close()
			mountsSand.Close()
			mountsGofer.Close()
			return nil, nil, nil, nil, fmt.Errorf("unable to run a rootless container without userns")
		}
		nss = append(nss, userNS)
		if sandbox.CanUseUnprivilegedMapping(c.Spec) {
			specutils.SetUIDGIDMappings(cmd, c.Spec)
			cmd.SysProcAttr.GidMappingsEnableSetgroups = false
		} else {
			setUserMappings = true
		}
	}

	log.Infof("Starting external gofer %q", conf.GoferBinary)
	if err := specutils.StartInNS(cmd, nss); err != nil {
		sandEnd.Close()
		mountsSand.Close()
		mountsGofer.Close()
		return nil, nil, nil, nil, fmt.Errorf("external gofer: %w", err)
	}
	goferEnd.Close()

	c.GoferPid.Store(cmd.Process.Pid)
	c.goferIsChild = true
	log.Infof("External gofer started, PID: %d", cmd.Process.Pid)

	if setUserMappings {
		if err := sandbox.SetUserMappings(c.Spec, cmd.Process.Pid); err != nil {
			return nil, nil, nil, nil, err
		}
	}

	mounts := append([]specs.Mount(nil), c.Spec.Mounts...)
	go func() {
		if err := sandboxsetup.WriteMounts(int(mountsGofer.Fd()), mounts); err != nil {
			log.Warningf("external gofer: failed to write mounts: %v", err)
		}
		if err := mountsGofer.Close(); err != nil {
			log.Warningf("external gofer: failed to close mounts pipe: %v", err)
		}
	}()

	if err := nvproxySetup(c.Spec, conf, c.GoferPid.Load()); err != nil {
		return nil, nil, nil, nil, fmt.Errorf("setting up nvproxy for external gofer: %w", err)
	}

	goferFilestores, err := c.createGoferFilestores(conf.GetOverlay2(), mountHints)
	if err != nil {
		return nil, nil, nil, nil, fmt.Errorf("creating gofer filestore files: %w", err)
	}

	return []*os.File{sandEnd}, goferFilestores, nil, mountsSand, nil
}

func lisafsMountCount(confs []specutils.GoferMountConf) int {
	n := 0
	for _, cfg := range confs {
		if cfg.ShouldUseLisafs() {
			n++
		}
	}
	return n
}
