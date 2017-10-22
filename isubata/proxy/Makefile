GOPATH := ${PWD}
export GOPATH

build: bin/isuroxy

dependency: deps
	@cat deps | xargs -n 1 go get -v

bin/isuroxy: dependency src/**/*.go
	@mkdir -p bin
	go build -o bin/isuroxy -v isuroxy
