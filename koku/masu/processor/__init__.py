#
# Copyright 2018 Red Hat, Inc.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
"""Masu Processor."""
import logging

from django.conf import settings

from masu.external import GZIP_COMPRESSED
from masu.external import UNCOMPRESSED

LOG = logging.getLogger(__name__)

ALLOWED_COMPRESSIONS = (UNCOMPRESSED, GZIP_COMPRESSED)


def enable_trino_processing(source_uuid, source_type, account):  # noqa
    """Helper to determine if source is enabled for Trino."""
    if account and not account.startswith("acct"):
        account = f"acct{account}"

    LOG.debug(f"enable_trino_processing({source_uuid}, {source_type}, {account})")
    if (
        settings.ENABLE_PARQUET_PROCESSING
        or source_uuid in settings.ENABLE_TRINO_SOURCES
        or source_type in settings.ENABLE_TRINO_SOURCE_TYPE
        or account in settings.ENABLE_TRINO_ACCOUNTS
    ):
        return True
    return False
