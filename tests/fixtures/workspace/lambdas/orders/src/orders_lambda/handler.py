"""Lambda entrypoint for the orders member of the workspace fixture."""

import common
from markupsafe import escape


def lambda_handler(event, context):
    """Echo the event back, escaped, serialised by the shared library."""
    return {
        "statusCode": 200,
        "body": common.dumps({"lambda": common.name_label("orders"), "event": str(escape(event))}),
    }
