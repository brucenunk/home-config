package daemon

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/brucenunk/home-config/go/herdsman/internal/app"
	"github.com/brucenunk/home-config/go/herdsman/internal/herdr"
)

func TestFinishBatchOver128SessionsIsAccepted(t *testing.T) {
	d := testDaemon(t, config(), backend(), logger(io.Discard))
	d.accepting = true
	server := httptest.NewServer(d.handler())
	defer server.Close()
	r := startRequest()
	r.Start = nil
	for n := 0; n < 129; n++ {
		name := fmt.Sprintf("agent-%d", n)
		r.Finish = append(r.Finish, app.FinishTarget{Machine: herdr.Local(), Agent: herdr.Agent{Name: name, PaneID: name + ":p1"}, Workspace: herdr.Workspace{ID: name, Label: name}})
	}
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
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
	if len(job.request.Finish) != 129 {
		t.Fatal("batch altered", len(job.request.Finish))
	}
}
