.PHONY: build check clean deps format release spec

build: deps
	shards build

deps:
	shards install --frozen

release: deps
	shards build --release

check: deps
	crystal tool format --check
	crystal spec
	shards build --release

format:
	crystal tool format

spec: deps
	crystal spec

clean:
	rm -rf bin .shards lib
