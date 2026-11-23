"""Small helpers that the workspace fixture's shared library pulls in by path."""


def label(name):
    """Return the name as a label for the response body."""
    return f"lambda:{name}"
