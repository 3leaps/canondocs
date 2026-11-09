// SPDX-License-Identifier: MIT OR Apache-2.0

// Command canondocs writes RFC 8785 (JCS) canonical JSON for JSON, YAML and
// NDJSON input.
package main

import (
	"os"
	"os/signal"
	"syscall"

	"github.com/3leaps/canondocs/internal/cli"
)

func main() {
	// Receive SIGPIPE instead of dying on it, so a write to a closed stdout
	// pipe returns EPIPE and is reported as success.
	signal.Notify(make(chan os.Signal, 1), syscall.SIGPIPE)
	os.Exit(cli.Main(os.Args[1:], cli.Env{Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr}))
}
