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

package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestValidateGoferBinary(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "gofer-shim")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		name    string
		path    string
		wantErr bool
	}{
		{"valid", bin, false},
		{"relative", "gofer-shim", true},
		{"missing", filepath.Join(dir, "nope"), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := &Config{GoferBinary: tc.path}
			err := c.validate()
			if (err != nil) != tc.wantErr {
				t.Fatalf("validate() = %v, wantErr %v", err, tc.wantErr)
			}
		})
	}
}
