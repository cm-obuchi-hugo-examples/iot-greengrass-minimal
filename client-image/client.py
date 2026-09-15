#!/usr/bin/env python3
"""Discover this device's Greengrass core, connect to it over local mTLS,
and then run forever: subscribe to this device's commands topic and publish
a telemetry heartbeat every 60 seconds.

Greengrass discovery is one HTTPS call (not MQTT) authenticated with this
device's own certificate against AWS IoT Core. It returns the discovered
core's local network address plus a group-specific local CA -- NOT the same
CA as the Amazon Root CA used only to trust the discovery endpoint itself.
The local mTLS connection that follows must trust that returned CA instead
of the Amazon Root CA.

This process is meant to never exit on its own once connected -- that's
what keeps the client container alive in steady state. It exits non-zero
if discovery or the initial local connection fails, so entrypoint.sh's own
backoff loop can retry (this script does not implement its own retry/backoff
for that). If the local connection is lost after being established, this
also exits non-zero rather than trying to reconnect and resubscribe itself
-- the outer loop restarts the whole process, including rediscovery, which
is the simple, correct behavior here (the core's local address can change).

Invoked by entrypoint.sh, every time, once a stored device certificate
exists (whether just obtained or reused from a previous boot).
"""
import argparse
import datetime
import os
import sys
import time

from awscrt import io, mqtt
from awsiot import mqtt_connection_builder
from awsiot.greengrass_discovery import DiscoveryClient

TOPIC_PREFIX = "lab/greengrass/devices"
TELEMETRY_INTERVAL_SECS = 60
DISCOVERY_TIMEOUT_SECS = 30
CONNECT_TIMEOUT_SECS = 30
SUBSCRIBE_TIMEOUT_SECS = 30


def fail(message):
    print(f"client.py: {message}", file=sys.stderr)
    sys.exit(1)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Discover this device's Greengrass core and run its persistent local MQTT session."
    )
    parser.add_argument("--thing_name", required=True, help="This device's own Thing name.")
    parser.add_argument("--cert", required=True, help="Path to this device's own certificate (PEM).")
    parser.add_argument("--key", required=True, help="Path to this device's own private key (PEM).")
    parser.add_argument(
        "--ca_file",
        required=True,
        help="CA used to trust the greengrass:Discover HTTPS endpoint (the Amazon Root CA). "
        "This is not the CA used for the local mTLS connection -- that CA comes back "
        "in the discovery response itself, per-group.",
    )
    parser.add_argument(
        "--region",
        default=os.environ.get("AWS_REGION", "ap-northeast-1"),
        help="AWS region to run greengrass:Discover against. Defaults to $AWS_REGION.",
    )
    return parser.parse_args()


def discover(thing_name, cert, key, ca_file, region):
    """Run greengrass:Discover once and return the parsed DiscoverResponse."""
    tls_options = io.TlsContextOptions.create_client_with_mtls_from_path(cert, key)
    tls_options.override_default_trust_store_from_path(None, ca_file)
    tls_context = io.ClientTlsContext(tls_options)
    socket_options = io.SocketOptions()

    discovery_client = DiscoveryClient(
        io.ClientBootstrap.get_or_create_static_default(),
        socket_options,
        tls_context,
        region,
    )

    print(f"client.py: discovering core for {thing_name} in {region}")
    try:
        return discovery_client.discover(thing_name).result(timeout=DISCOVERY_TIMEOUT_SECS)
    except Exception as exc:  # noqa: BLE001 - top-level entrypoint, any failure means "retry me"
        fail(f"discovery failed: {exc}")


def on_connection_interrupted(connection, error, **kwargs):
    # The underlying MQTT client will try to reconnect on its own, but this
    # lab deliberately does not want that: a lost connection means the core
    # may have moved (new local IP), so the right move is a fresh discovery,
    # not a silent background reconnect with no resubscribe. Exiting here
    # forces entrypoint.sh's loop to restart this whole process from
    # scratch. os._exit (not sys.exit) because this callback does not run
    # on the main thread.
    print(f"client.py: local connection interrupted: {error}", file=sys.stderr)
    os._exit(1)


def connect(thing_name, cert, key, discover_response):
    """Try every discovered core/connectivity candidate once; return the
    first live connection, or fail() if none connects."""
    for gg_group in discover_response.gg_groups or []:
        for gg_core in gg_group.cores or []:
            for info in gg_core.connectivity or []:
                print(
                    f"client.py: trying core {gg_core.thing_arn} at "
                    f"{info.host_address}:{info.port}"
                )
                connection = mqtt_connection_builder.mtls_from_path(
                    endpoint=info.host_address,
                    port=info.port,
                    cert_filepath=cert,
                    pri_key_filepath=key,
                    ca_bytes=gg_group.certificate_authorities[0].encode("utf-8"),
                    on_connection_interrupted=on_connection_interrupted,
                    client_id=thing_name,
                    clean_session=False,
                    keep_alive_secs=30,
                )
                try:
                    connection.connect().result(timeout=CONNECT_TIMEOUT_SECS)
                except Exception as exc:  # noqa: BLE001 - just try the next candidate
                    print(f"client.py: connect failed: {exc}", file=sys.stderr)
                    continue
                print(f"client.py: connected to {info.host_address}:{info.port}")
                return connection

    fail("no discovered core/connectivity candidate could be connected to")


def on_command(topic, payload, **kwargs):
    decoded = payload.decode("utf-8", errors="replace")
    print(f"received command: {decoded}")


def subscribe_commands(connection, thing_name):
    topic = f"{TOPIC_PREFIX}/{thing_name}/commands"
    subscribed, _ = connection.subscribe(topic, mqtt.QoS.AT_LEAST_ONCE, on_command)
    try:
        subscribed.result(timeout=SUBSCRIBE_TIMEOUT_SECS)
    except Exception as exc:  # noqa: BLE001 - top-level entrypoint
        fail(f"subscribe to {topic} failed: {exc}")
    print(f"client.py: subscribed to {topic}")


def publish_telemetry_forever(connection, thing_name):
    topic = f"{TOPIC_PREFIX}/{thing_name}/telemetry"
    while True:
        timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        message = f"{thing_name} ticking time: {timestamp}"
        connection.publish(topic, message, mqtt.QoS.AT_LEAST_ONCE)
        print(f"published to {topic}: {message}")
        time.sleep(TELEMETRY_INTERVAL_SECS)


def main():
    args = parse_args()

    discover_response = discover(args.thing_name, args.cert, args.key, args.ca_file, args.region)
    connection = connect(args.thing_name, args.cert, args.key, discover_response)
    subscribe_commands(connection, args.thing_name)

    # Never returns under normal operation -- see the module docstring for
    # what happens instead when the connection is lost.
    publish_telemetry_forever(connection, args.thing_name)


if __name__ == "__main__":
    main()
