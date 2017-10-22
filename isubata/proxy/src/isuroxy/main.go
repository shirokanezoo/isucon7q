package main

import (
	"os"
	"strconv"
	"time"
)

func main() {
	backend := os.Getenv("ISUROXY_BACKEND")
	if len(backend) == 0 {
		backend = "localhost:5000"
	}

	timeout := os.Getenv("ISUROXY_TIMEOUT")
	if len(timeout) == 0 {
		timeout = "5"
	}

	ts, err := strconv.Atoi(timeout)
	if ts == 0 || err != nil {
		ts = 5
	}

	s := &Server{
		Backend: backend,
		Timeout: time.Duration(ts) * time.Second,
	}

	s.Start()
}
