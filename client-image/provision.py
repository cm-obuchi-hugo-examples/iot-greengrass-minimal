#!/usr/bin/env python3
"""Fleet-provision this device by claim.

Connects with the shared claim certificate, exchanges a locally generated
CSR for a unique device certificate (CreateCertificateFromCsr), then
registers the resulting Thing through lab-gg-client-template
(RegisterThing) with this device's serial number as the template's only
parameter. Writes the issued certificate to --out and exits.

The private key that produced --csr never leaves the container: only the
CSR (already a public artifact once signed) is sent over the claim
connection. The Thing name, thing-group membership, and IoT policy are all
decided by lab-gg-client-template on the server side, not by this script —
see infra/20-fleet/provisioning-template.tf.

Invoked by entrypoint.sh, once, only when no stored identity exists yet
for this device's serial.
"""
import argparse
import concurrent.futures
import os
import sys

from awscrt import mqtt
from awsiot import iotidentity, mqtt_connection_builder

# Fixed lab constants. Every client uses the same provisioning template and
# mounts the same read-only claim identity at these fixed paths
# (local/compose.yaml: "../certs/claim:/claim:ro").
TEMPLATE_NAME = "lab-gg-client-template"
CLAIM_CERT_PATH = "/claim/claim.pem.crt"
CLAIM_KEY_PATH = "/claim/private.pem.key"
CLAIM_CA_PATH = "/claim/AmazonRootCA1.pem"

# How long to wait for each MQTT round trip (connect, subscribe, the
# CreateCertificateFromCsr and RegisterThing responses) before giving up.
# Provisioning runs once at first boot, so a generous timeout costs nothing.
REQUEST_TIMEOUT_SECS = 30


def fail(message):
    print(f"provision.py: {message}", file=sys.stderr)
    sys.exit(1)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Fleet-provision this device by claim, using lab-gg-client-template."
    )
    parser.add_argument(
        "--serial", required=True, help="This device's serial number (becomes lab-gg-device-<serial>)."
    )
    parser.add_argument("--csr", required=True, help="Path to this device's CSR (PEM).")
    parser.add_argument("--out", required=True, help="Path to write the issued device certificate (PEM).")
    parser.add_argument(
        "--endpoint",
        default=os.environ.get("IOT_DATA_ENDPOINT"),
        help="AWS IoT data (ATS) endpoint. Defaults to $IOT_DATA_ENDPOINT.",
    )
    parser.add_argument(
        "--region",
        default=os.environ.get("AWS_REGION", "ap-northeast-1"),
        help="AWS region, used only for log context. Defaults to $AWS_REGION.",
    )
    args = parser.parse_args()
    if not args.endpoint:
        fail("no endpoint given: pass --endpoint or set IOT_DATA_ENDPOINT")
    return args


def _resolve_once(future, response):
    """Set a Future's result exactly once; the SDK may retry a callback."""
    if not future.done():
        future.set_result(response)


def _first_result(accepted, rejected, operation):
    """Return whichever of the accepted/rejected futures resolves first."""
    done, _ = concurrent.futures.wait(
        [accepted, rejected],
        timeout=REQUEST_TIMEOUT_SECS,
        return_when=concurrent.futures.FIRST_COMPLETED,
    )
    if not done:
        fail(f"{operation}: no response within {REQUEST_TIMEOUT_SECS}s")
    return done.pop().result()


def create_certificate_from_csr(identity, csr_text):
    accepted = concurrent.futures.Future()
    rejected = concurrent.futures.Future()

    sub_accepted, _ = identity.subscribe_to_create_certificate_from_csr_accepted(
        request=iotidentity.CreateCertificateFromCsrSubscriptionRequest(),
        qos=mqtt.QoS.AT_LEAST_ONCE,
        callback=lambda response: _resolve_once(accepted, response),
    )
    sub_rejected, _ = identity.subscribe_to_create_certificate_from_csr_rejected(
        request=iotidentity.CreateCertificateFromCsrSubscriptionRequest(),
        qos=mqtt.QoS.AT_LEAST_ONCE,
        callback=lambda response: _resolve_once(rejected, response),
    )
    sub_accepted.result(timeout=REQUEST_TIMEOUT_SECS)
    sub_rejected.result(timeout=REQUEST_TIMEOUT_SECS)

    identity.publish_create_certificate_from_csr(
        iotidentity.CreateCertificateFromCsrRequest(certificate_signing_request=csr_text),
        mqtt.QoS.AT_LEAST_ONCE,
    ).result(timeout=REQUEST_TIMEOUT_SECS)

    response = _first_result(accepted, rejected, "CreateCertificateFromCsr")
    if isinstance(response, iotidentity.ErrorResponse):
        fail(f"CreateCertificateFromCsr rejected: {response.error_code} {response.error_message}")
    return response.certificate_pem, response.certificate_ownership_token


def register_thing(identity, serial, certificate_ownership_token):
    accepted = concurrent.futures.Future()
    rejected = concurrent.futures.Future()

    sub_accepted, _ = identity.subscribe_to_register_thing_accepted(
        request=iotidentity.RegisterThingSubscriptionRequest(template_name=TEMPLATE_NAME),
        qos=mqtt.QoS.AT_LEAST_ONCE,
        callback=lambda response: _resolve_once(accepted, response),
    )
    sub_rejected, _ = identity.subscribe_to_register_thing_rejected(
        request=iotidentity.RegisterThingSubscriptionRequest(template_name=TEMPLATE_NAME),
        qos=mqtt.QoS.AT_LEAST_ONCE,
        callback=lambda response: _resolve_once(rejected, response),
    )
    sub_accepted.result(timeout=REQUEST_TIMEOUT_SECS)
    sub_rejected.result(timeout=REQUEST_TIMEOUT_SECS)

    identity.publish_register_thing(
        iotidentity.RegisterThingRequest(
            template_name=TEMPLATE_NAME,
            certificate_ownership_token=certificate_ownership_token,
            parameters={"SerialNumber": serial},
        ),
        mqtt.QoS.AT_LEAST_ONCE,
    ).result(timeout=REQUEST_TIMEOUT_SECS)

    response = _first_result(accepted, rejected, "RegisterThing")
    if isinstance(response, iotidentity.ErrorResponse):
        fail(f"RegisterThing rejected: {response.error_code} {response.error_message}")
    return response.thing_name


def main():
    args = parse_args()

    with open(args.csr, "r") as f:
        csr_text = f.read()

    client_id = f"claim-{args.serial}"
    connection = mqtt_connection_builder.mtls_from_path(
        endpoint=args.endpoint,
        cert_filepath=CLAIM_CERT_PATH,
        pri_key_filepath=CLAIM_KEY_PATH,
        ca_filepath=CLAIM_CA_PATH,
        client_id=client_id,
        clean_session=True,
        keep_alive_secs=30,
    )

    print(f"provision.py: connecting to {args.endpoint} ({args.region}) as {client_id}")
    try:
        connection.connect().result(timeout=REQUEST_TIMEOUT_SECS)
    except Exception as exc:  # noqa: BLE001 - this is the top-level entrypoint
        fail(f"could not connect with the claim certificate: {exc}")

    try:
        identity = iotidentity.IotIdentityClient(connection)

        certificate_pem, certificate_ownership_token = create_certificate_from_csr(identity, csr_text)
        thing_name = register_thing(identity, args.serial, certificate_ownership_token)

        with open(args.out, "w") as f:
            f.write(certificate_pem)
        os.chmod(args.out, 0o600)

        print(f"provision.py: provisioned {thing_name}, wrote {args.out}")
    finally:
        connection.disconnect().result(timeout=REQUEST_TIMEOUT_SECS)


if __name__ == "__main__":
    main()
