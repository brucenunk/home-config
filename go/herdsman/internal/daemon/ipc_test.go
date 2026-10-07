package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
)

func TestIPCValidationAndPromptRedaction(t *testing.T) {
	d := testDaemon(t, config(), backend(), logger(io.Discard))
	d.accepting = true
	server := httptest.NewServer(d.handler())
	defer server.Close()
	for _, body := range []string{
		"not json", "{} {}", `{"ConfigID":"wrong","Start":{}}`, `{"unexpected":"secret body"}`, strings.Repeat("x", 4*1024*1024+1),
	} {
		response, err := http.Post(server.URL+"/requests", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		data, _ := io.ReadAll(response.Body)
		response.Body.Close()
		if response.StatusCode < 400 || strings.Contains(string(data), "secret body") {
			t.Fatal(response.StatusCode, string(data))
		}
	}
	if len(d.queue) != 0 {
		t.Fatal("invalid requests queued")
	}
}
func TestUnixSocketRoundTripAndShutdown(t *testing.T) {
	path := socketTestPath(t)
	f := backend()
	d := testDaemon(t, config(), f, logger(io.Discard))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f.createEntered = make(chan struct{}, 1)
	f.createRelease = make(chan struct{})
	done := make(chan error, 1)
	go func() { done <- d.Serve(ctx, path) }()
	client := NewClient(path)
	defer client.Close()
	eventually(t, func() bool {
		i, err := client.Inventory(context.Background())
		return err == nil && !i.ProfilesUpdated.IsZero()
	})
	i, err := client.Inventory(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := i.CheckConfig(config()); err != nil {
		t.Fatal(err)
	}
	if err := client.Submit(context.Background(), startRequest()); err != nil {
		t.Fatal(err)
	}
	select {
	case <-f.createEntered:
	case <-time.After(time.Second):
		t.Fatal("accepted request not executed")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("serve did not shut down")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("socket not removed", err)
	}
	if _, err := client.Inventory(context.Background()); err == nil || !strings.Contains(err.Error(), "unavailable") {
		t.Fatal(err)
	}
}
func TestSocketSingleOwnerAndPrivateDirectory(t *testing.T) {
	path := socketTestPath(t)
	listener, cleanup, err := listen(path)
	if err != nil {
		t.Fatal(err)
	}
	if second, clean, err := listen(path); err == nil {
		second.Close()
		clean()
		t.Fatal("second daemon acquired socket")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("second daemon removed live socket")
	}
	listener.Close()
	cleanup()
	if err := os.WriteFile(path, []byte("abandoned"), 0600); err != nil {
		t.Fatal(err)
	}
	listener, cleanup, err = listen(path)
	if err != nil {
		t.Fatal("cannot recover abandoned socket", err)
	}
	listener.Close()
	cleanup()
	dir := t.TempDir()
	if err := os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if listener, cleanup, err := listen(filepath.Join(dir, "socket")); err == nil {
		listener.Close()
		cleanup()
		t.Fatal("insecure directory accepted")
	}
}

// Darwin Unix socket paths have a small limit; Go's test-name temp paths can
// exceed it even though the production cache/runtime path fits.
func socketTestPath(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "hs-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return filepath.Join(dir, "daemon.sock")
}

func TestMaximumEscapedTaskRoundTrip(t *testing.T) {
	d := testDaemon(t, config(), backend(), logger(io.Discard))
	d.accepting = true
	server := httptest.NewServer(d.handler())
	defer server.Close()
	r := startRequest()
	r.Start.Repo = "owner/repo"
	r.Start.BaseRef = "origin/main"
	r.Start.Model, r.Start.Thinking = "example/vendor/model", "high"
	r.Start.Task = &app.Task{Title: strings.Repeat("<", 120*1024), Body: strings.Repeat("<", 120*1024)}
	r.Start.Task.Repo, r.Start.Task.Machine = "owner/repo", "machine-a"
	r.Start.Task.Model, r.Start.Task.Thinking = "example/vendor/model", "medium"
	// Task selection can retain a previously entered valid description.
	r.Start.Description = strings.Repeat("<", 120*1024)
	if err := r.Start.Task.ValidateTransport(); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) < 1024*1024 {
		t.Fatal("test does not exercise escaping overhead")
	}
	response, err := http.Post(server.URL+"/requests", "application/json", strings.NewReader(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(response.Body)
		t.Fatal(response.StatusCode, string(body))
	}
	job := <-d.queue
	if job.request.Start.BaseRef != r.Start.BaseRef || job.request.Start.Model != r.Start.Model || job.request.Start.Thinking != r.Start.Thinking || job.request.Start.Task.Machine != "machine-a" {
		t.Fatal("choices or hints altered during IPC", job.request.Start)
	}
	if job.request.Start.Task.Body != r.Start.Task.Body || job.request.Start.Task.Title != r.Start.Task.Title {
		t.Fatal("task altered during IPC")
	}
}

func TestClientPreservesExplicitRejection(t *testing.T) {
	d := testDaemon(t, config(), backend(), logger(io.Discard))
	d.accepting = true
	for n := 0; n < config().Daemon.QueueCapacity; n++ {
		if err := d.Submit(startRequest()); err != nil {
			t.Fatal(err)
		}
	}
	path := socketTestPath(t)
	listener, cleanup, err := listen(path)
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	server := &http.Server{Handler: d.handler()}
	defer server.Close()
	go func() { _ = server.Serve(listener) }()
	client := NewClient(path)
	defer client.Close()
	err = client.Submit(context.Background(), startRequest())
	var rejection *Rejection
	if !errors.As(err, &rejection) || rejection.Status != http.StatusConflict || !strings.Contains(rejection.Reason, "full") {
		t.Fatal(err)
	}
}
