package main

import (
	"github.com/go-redis/redis"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"time"
)

const STREAM_KEY = "isubata:stream:message"

type receiver chan struct{}

type Server struct {
	redis     *redis.Client
	receivers chan receiver

	Backend string
	Timeout time.Duration
}

func (s *Server) Wait() {
	rec := make(receiver, 1)
	s.receivers <- rec

	select {
	case <-rec:
		return
	case <-time.After(s.Timeout):
		return
	}
}

func (s *Server) Director(request *http.Request) {
	s.Wait()
	request.URL.Scheme = "http"
	request.URL.Host = s.Backend
}

func (s *Server) initRedis() {
	redisURL := os.Getenv("ISUBATA_REDIS_URL")
	if len(redisURL) == 0 {
		redisURL = "redis://localhost:6379/0"
	}

	u, err := url.Parse(redisURL)
	if err != nil {
		log.Println("Can't parse redis URL. Check your ISUBATA_REDIS_URL")
		log.Fatal(err.Error())
	}

	s.redis = redis.NewClient(&redis.Options{
		Addr: u.Host,
		DB:   0, // use default DB
	})

	_, err = s.redis.Ping().Result()
	if err != nil {
		log.Println("Can't connect to redis. Check your ISUBATA_REDIS_URL")
		log.Fatal(err.Error())
	}

	go func() {
		for {
			pubsub := s.redis.Subscribe(STREAM_KEY)

			for {
				_, err := pubsub.ReceiveMessage()
				if err != nil {
					log.Println("PubSub error")
					log.Fatal(err.Error())
					break
				}

				for rec := range s.receivers {
					rec <- struct{}{}
				}
			}
		}
	}()
}

func (s *Server) Start() {
	s.receivers = make(chan receiver, 1000)
	s.initRedis()

	rp := &httputil.ReverseProxy{Director: s.Director}
	server := http.Server{
		Addr:    ":9000",
		Handler: rp,
	}

	log.Println("=== Started ===")
	log.Printf("Backend: %s / Timeout: %s", s.Backend, s.Timeout)

	if err := server.ListenAndServe(); err != nil {
		log.Fatal(err.Error())
	}
}
