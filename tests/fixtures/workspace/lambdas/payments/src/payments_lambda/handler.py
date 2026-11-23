"""Lambda entrypoint for the payments member of the workspace fixture."""

import common


def lambda_handler(event, context):
    """Echo the event back, serialised by the shared library."""
    return {
        "statusCode": 200,
        "body": common.dumps({"lambda": common.name_label("payments"), "event": event}),
    }
