"""Shared code for the lambdas in the workspace fixture."""

import orjson
from textutil import label


def dumps(value):
    """Serialise a value with the compiled dependency."""
    return orjson.dumps(value).decode()


def name_label(name):
    """Label a lambda by name, with the path dependency."""
    return label(name)
