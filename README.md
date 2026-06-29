# mqhole

`mqhole` is a small Crystal CLI for moving bytes between two parties that know
the same CloudAMQP team API key and wormhole name. It provisions or reuses one
shared LavinMQ CloudAMQP subscription, then uses AMQP(S) durable queues as the
transport.

This is a transport tool, not a PAKE/encryption implementation like upstream
magic-wormhole. The shared name is hashed into a queue name; anyone with the
CloudAMQP API key can access the same broker.

## Requirements

- Crystal 1.20.2 or newer
- A CloudAMQP team API key

Install dependencies and build:

```sh
shards install
shards build
```

The binary is written to `bin/mqhole`.

## CloudAMQP

Set the API key in the environment:

```sh
export CLOUDAMQP_API_KEY=...
```

The send and receive commands default to `scaleway::nl-ams`, which CloudAMQP
currently reports as supporting shared plans. List regions with shared plans and
pass one with `--region` if you want a different broker location:

```sh
bin/mqhole regions --shared-only
bin/mqhole regions scaleway
```

`mqhole` creates an instance named after the selected region, for example
`mqhole-lavinmq-scaleway-nl-ams`, and reuses it on later runs.

## Usage

Send stdin:

```sh
printf 'hello\n' | bin/mqhole send demo
```

Receive and echo to stdout:

```sh
bin/mqhole receive demo
```

Send and receive a file:

```sh
bin/mqhole send demo --file ./payload.bin

bin/mqhole receive demo --output ./received.bin --no-echo
```

Run a hook with the temporary payload path:

```sh
bin/mqhole receive demo --hook 'sha256sum' --hook-mode file --no-echo
```

Run a hook with the payload as one process argument:

```sh
bin/mqhole receive demo --hook 'printf %s' --hook-mode argument --no-echo
```

Argument hook mode is intended for text payloads. It rejects payloads containing
NUL bytes because those cannot be represented safely as process arguments.

## Development

Run the checks used by CI:

```sh
crystal tool format --check
crystal spec
shards build
```

The live smoke test used during development sent and received data through a
real CloudAMQP LavinMQ instance in `scaleway::nl-ams`.
