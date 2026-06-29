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

The send and receive commands default to `digital-ocean::ams3`. CloudAMQP
currently reports DigitalOcean Amsterdam as not supporting shared plans, so the
free LavinMQ `lemming` plan cannot be created there. List regions with shared
plans and pass one with `--region`:

```sh
bin/mqhole regions --shared-only
bin/mqhole regions digital-ocean
```

`mqhole` creates an instance named after the selected region, for example
`mqhole-lavinmq-amazon-web-services-eu-west-1`, and reuses it on later runs.

## Usage

Send stdin:

```sh
printf 'hello\n' | bin/mqhole send demo \
  --region amazon-web-services::eu-west-1
```

Receive and echo to stdout:

```sh
bin/mqhole receive demo \
  --region amazon-web-services::eu-west-1
```

Send and receive a file:

```sh
bin/mqhole send demo --file ./payload.bin \
  --region amazon-web-services::eu-west-1

bin/mqhole receive demo --output ./received.bin --no-echo \
  --region amazon-web-services::eu-west-1
```

Run a hook with the temporary payload path:

```sh
bin/mqhole receive demo --hook 'sha256sum' --hook-mode file --no-echo \
  --region amazon-web-services::eu-west-1
```

Run a hook with the payload as one process argument:

```sh
bin/mqhole receive demo --hook 'printf %s' --hook-mode argument --no-echo \
  --region amazon-web-services::eu-west-1
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
real CloudAMQP LavinMQ instance in `amazon-web-services::eu-west-1`.
