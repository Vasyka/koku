#
# Copyright 2020 Red Hat, Inc.
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
"""Test the clone_schema functionality."""
from unittest.mock import patch

from django.core.exceptions import ValidationError
from django.db import connection as conn
from django.db import DatabaseError
from tenant_schemas.utils import schema_exists

from ..models import CloneSchemaFuncMissing
from ..models import CloneSchemaTemplateMissing
from ..models import Tenant
from ..models import TENANT_SUPPORT
from .iam_test_case import IamTestCase
from koku.database import dbfunc_not_exists


def _verify_clone_funcs():
    func_map = {
        Tenant._READ_SCHEMA_FUNC_SCHEMA: {
            Tenant._READ_SCHEMA_FUNC_NAME: Tenant._READ_SCHEMA_FUNC_SIG,
            Tenant._CREATE_SCHEMA_FUNC_NAME: Tenant._CREATE_SCHEMA_FUNC_SIG,
        }
    }
    res = dbfunc_not_exists(conn, func_map)
    return res


def _drop_clone_funcs():
    sql = f"""
drop function if exists {Tenant._READ_SCHEMA_FUNC_NAME.replace(' DEFAULT false', '')} ;
drop function if exists {Tenant._CREATE_SCHEMA_FUNC_SIG.replace(' DEFAULT false', '')} ;
"""
    with conn.cursor() as cur:
        cur.execute(sql, None)


def _drop_template_schema():
    sql = f"""
drop schema if exists {Tenant._TEMPLATE_SCHEMA} cascade ;
"""
    with conn.cursor() as cur:
        cur.execute(sql, None)


def _delete_tenant_record():
    sql = """
delete
  from public.api_tenant
 where schema_name = %s ;
"""
    with conn.cursor() as cur:
        cur.execute(sql, (Tenant._TEMPLATE_SCHEMA,))


class AutoCloneSchemaTest(IamTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.__save_auto_create_schema = Tenant.auto_create_schema
        Tenant.auto_create_schema = True

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        Tenant.auto_create_schema = cls.__save_auto_create_schema

    def setUp(self):
        TENANT_SUPPORT.clear()

    def test_auto_create_schema_true(self):
        """
        Test that Tenant class auto_create_schema value is True
        """
        self.assertTrue(Tenant.auto_create_schema)

    def test_create_schema(self):
        """
        Test that the cloned schema has all of the objects, data of the template
        """

    def test_create_template_schema(self):
        """
        Test that the template schema can be created directly or indirectly
        """
        Tenant.objects.filter(schema_name=Tenant._TEMPLATE_SCHEMA).delete()
        self.assertFalse(schema_exists(Tenant._TEMPLATE_SCHEMA))

        # Also validate that the template will be created using migrations
        expected = f'INFO:api.iam.models:Using superclass for "{Tenant._TEMPLATE_SCHEMA}" schema creation'
        with self.assertLogs("api.iam.models", level="INFO") as _logger:
            Tenant(schema_name=Tenant._TEMPLATE_SCHEMA).save()
            self.assertIn(expected, _logger.output)
        self.assertTrue(schema_exists(Tenant._TEMPLATE_SCHEMA))

        Tenant.objects.filter(schema_name=Tenant._TEMPLATE_SCHEMA).delete()
        self.assertFalse(schema_exists(Tenant._TEMPLATE_SCHEMA))

        test_schema = "acct90909090"
        # Also validate that the customer tenant schema will be created using the clone function
        expected1 = f'INFO:api.iam.models:Cloning template schema "{Tenant._TEMPLATE_SCHEMA}" to "{test_schema}"'
        expected2 = f'INFO:api.iam.models:Successful clone of "{Tenant._TEMPLATE_SCHEMA}" to "{test_schema}"'
        with self.assertLogs("api.iam.models", level="INFO") as _logger:
            Tenant(schema_name=test_schema).save()
            self.assertIn(expected1, _logger.output)
            self.assertIn(expected2, _logger.output)
        self.assertTrue(schema_exists(Tenant._TEMPLATE_SCHEMA))
        self.assertTrue(schema_exists(test_schema))

    def test_clone_schema_missing_clone_func(self):
        """
        Test that the clone function will be applied if it is missing and the clone will succeed
        """
        _drop_clone_funcs()
        self.assertTrue(_verify_clone_funcs())

        test_schema = "acct90909091"
        self.assertFalse(schema_exists(test_schema))
        Tenant(schema_name=test_schema).save()
        self.assertFalse(_verify_clone_funcs())
        self.assertTrue(schema_exists(test_schema))

    def test_has_template_rec_missing_template_schema(self):
        """
        Test that am existing template tenant record with a missing tenant schema will throw an exception
        """
        _drop_template_schema()
        self.assertFalse(schema_exists(Tenant._TEMPLATE_SCHEMA))

        test_schema = "acct90909092"
        with patch("api.iam.models.Tenant._verify_template", return_value=False):
            with self.assertRaises(CloneSchemaTemplateMissing):
                Tenant(schema_name=test_schema).save()

        Tenant.objects.filter(schema_name=Tenant._TEMPLATE_SCHEMA).delete()
        Tenant(schema_name=test_schema).save()
        self.assertTrue(schema_exists(test_schema))
        self.assertTrue(schema_exists(Tenant._TEMPLATE_SCHEMA))

    def test_tenant_object_delete_leaves_template(self):
        """
        Test that deleting a customer schema will leave the template schema untouched
        """
        cust_tenant = "acct90909093"
        self.assertFalse(schema_exists(cust_tenant))
        self.assertTrue(schema_exists(Tenant._TEMPLATE_SCHEMA))

        Tenant(schema_name=cust_tenant).save()
        self.assertTrue(schema_exists(cust_tenant))

        Tenant.objects.filter(schema_name=cust_tenant).delete()
        self.assertFalse(schema_exists(cust_tenant))
        self.assertTrue(schema_exists(Tenant._TEMPLATE_SCHEMA))

    def test_clone_func_create_fail(self):
        """
        Test that a failed re-application of the clone function is caught and logged
        """
        with patch("api.iam.models.Tenant._check_clone_func", return_value=False):
            with self.assertRaises(CloneSchemaFuncMissing):
                Tenant(schema_name="test_clone_func_create_fail").create_schema()

    def test_clone_schema_exception(self):
        """
        Test that a DatabaseError is raised from within the call is logged and handled
        """
        tst_schema = "test_clone_schema_exception"
        expected = 'ERROR:api.iam.models:Exception DatabaseError cloning "{}" to "{}": Too Many Quatloos'.format(
            Tenant._TEMPLATE_SCHEMA, tst_schema
        )
        with patch("api.iam.models.Tenant._clone_schema", side_effect=DatabaseError("Too Many Quatloos")):
            with self.assertLogs("api.iam.models", level="INFO") as _logger:
                with self.assertRaises(DatabaseError):
                    Tenant(schema_name=tst_schema).create_schema()
                    self.assertIn(expected, _logger.output)

    def test_create_existing_schema(self):
        """
        Test that creating an existing schema will return false and leave schema intact
        """
        raw_conn = conn.connection
        with raw_conn.cursor() as cur:
            cur.execute("""create schema if not exists "eek01";""")
            cur.execute("""create table if not exists "eek01"."tab01" (id serial primary key, data text);""")

        # Verify that the existing schema was detected
        expected = 'WARNING:api.iam.models:Schema "eek01" already exists. Exit with False.'
        with self.assertLogs("api.iam.models", level="INFO") as _logger:
            Tenant(schema_name="eek01").save()
            self.assertIn(expected, _logger.output)

        # Verify that tenant record was created
        self.assertEqual(Tenant.objects.filter(schema_name="eek01").count(), 1)

        # Verify that no changes were made to existing schema
        with raw_conn.cursor() as cur:
            cur.execute("""select count(*) as ct from information_schema.tables where table_schema = 'eek01';""")
            res = cur.fetchone()[0]
            self.assertEqual(res, 1)

        # Verify that delete of tenant will also drop schema that existed
        Tenant.objects.filter(schema_name="eek01").delete()
        with raw_conn.cursor() as cur:
            cur.execute("""select count(*) from pg_namespace where nspname = 'eek01';""")
            res = cur.fetchone()[0]
            self.assertEqual(res, 0)

    def test_create_bad_tenant_name(self):
        """
        Test that creating a tenant with a bad name will throw an exception
        """
        with self.assertRaises(ValidationError):
            Tenant.objects.create(schema_name="bad schema-name")


class ManualCloneSchemaTest(IamTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.__save_auto_create_schema = Tenant.auto_create_schema
        Tenant.auto_create_schema = False

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        Tenant.auto_create_schema = cls.__save_auto_create_schema

    def setUp(self):
        TENANT_SUPPORT.clear()

    def test_auto_create_schema_false(self):
        """
        Test that Tenant class auto_create_schema value is False
        """
        self.assertFalse(Tenant.auto_create_schema)

    def test_create_template_schema(self):
        """
        Test that the template schema can be created directly or indirectly
        """
        Tenant.objects.filter(schema_name=Tenant._TEMPLATE_SCHEMA).delete()
        self.assertFalse(schema_exists(Tenant._TEMPLATE_SCHEMA))

        # Also validate that the template will be created using migrations
        expected = f'INFO:api.iam.models:Using superclass for "{Tenant._TEMPLATE_SCHEMA}" schema creation'
        with self.assertLogs("api.iam.models", level="INFO") as _logger:
            t = Tenant(schema_name=Tenant._TEMPLATE_SCHEMA)
            t.save()
            self.assertNotIn(expected, _logger.output)
            t.create_schema()
            self.assertIn(expected, _logger.output)
        self.assertTrue(schema_exists(Tenant._TEMPLATE_SCHEMA))

        Tenant.objects.filter(schema_name=Tenant._TEMPLATE_SCHEMA).delete()
        self.assertFalse(schema_exists(Tenant._TEMPLATE_SCHEMA))

        test_schema = "acct90909090"
        # Also validate that the customer tenant schema will be created using the clone function
        expected1 = f'INFO:api.iam.models:Cloning template schema "{Tenant._TEMPLATE_SCHEMA}" to "{test_schema}"'
        expected2 = f'INFO:api.iam.models:Successful clone of "{Tenant._TEMPLATE_SCHEMA}" to "{test_schema}"'
        with self.assertLogs("api.iam.models", level="INFO") as _logger:
            t = Tenant(schema_name=test_schema)
            t.save()
            self.assertNotIn(expected1, _logger.output)
            self.assertNotIn(expected2, _logger.output)
            t.create_schema()
            self.assertIn(expected1, _logger.output)
            self.assertIn(expected2, _logger.output)
        self.assertTrue(schema_exists(Tenant._TEMPLATE_SCHEMA))
        self.assertTrue(schema_exists(test_schema))

    def test_clone_schema_missing_clone_func(self):
        """
        Test that the clone function will be applied if it is missing and the clone will succeed
        """
        _drop_clone_funcs()
        self.assertTrue(_verify_clone_funcs())

        test_schema = "acct90909091"
        self.assertFalse(schema_exists(test_schema))
        t = Tenant(schema_name=test_schema)
        t.save()
        t.create_schema()
        self.assertFalse(_verify_clone_funcs())
        self.assertTrue(schema_exists(test_schema))

    def test_has_template_rec_missing_template_schema(self):
        """
        Test that am existing template tenant record with a missing tenant schema will throw an exception
        """
        _drop_template_schema()
        self.assertFalse(schema_exists(Tenant._TEMPLATE_SCHEMA))

        test_schema = "acct90909092"
        with patch("api.iam.models.Tenant._verify_template", return_value=False):
            with self.assertRaises(CloneSchemaTemplateMissing):
                t = Tenant.objects.create(schema_name=test_schema)
                t.create_schema()

        Tenant.objects.filter(schema_name__in=(Tenant._TEMPLATE_SCHEMA, test_schema)).delete()

        t = Tenant.objects.create(schema_name=test_schema)
        t.create_schema()
        self.assertTrue(schema_exists(test_schema))
        self.assertTrue(schema_exists(Tenant._TEMPLATE_SCHEMA))

    def test_tenant_object_delete_leaves_template(self):
        """
        Test that deleting a customer schema will leave the template schema untouched
        """
        cust_tenant = "acct90909093"
        self.assertFalse(schema_exists(cust_tenant))
        self.assertTrue(schema_exists(Tenant._TEMPLATE_SCHEMA))

        t = Tenant.objects.create(schema_name=cust_tenant)
        t.create_schema()
        self.assertTrue(schema_exists(cust_tenant))

        t.delete()
        self.assertFalse(schema_exists(cust_tenant))
        self.assertTrue(schema_exists(Tenant._TEMPLATE_SCHEMA))

    def test_clone_func_create_fail(self):
        """
        Test that a failed re-application of the clone function is caught and logged
        """
        with patch("api.iam.models.Tenant._check_clone_func", return_value=False):
            with self.assertRaises(CloneSchemaFuncMissing):
                Tenant(schema_name="test_clone_func_create_fail").create_schema()

    def test_clone_schema_exception(self):
        """
        Test that a DatabaseError is raised from within the call is logged and handled
        """
        tst_schema = "test_clone_schema_exception"
        expected = 'ERROR:api.iam.models:Exception DatabaseError cloning "{}" to "{}": Too Many Quatloos'.format(
            Tenant._TEMPLATE_SCHEMA, tst_schema
        )
        with patch("api.iam.models.Tenant._clone_schema", side_effect=DatabaseError("Too Many Quatloos")):
            with self.assertLogs("api.iam.models", level="INFO") as _logger:
                with self.assertRaises(DatabaseError):
                    Tenant(schema_name=tst_schema).create_schema()
                    self.assertIn(expected, _logger.output)

    def test_create_existing_schema(self):
        """
        Test that creating an existing schema will return false and leave schema intact
        """
        raw_conn = conn.connection
        with raw_conn.cursor() as cur:
            cur.execute("""create schema if not exists "eek01";""")
            cur.execute("""create table if not exists "eek01"."tab01" (id serial primary key, data text);""")

        # Verify that the existing schema was detected
        expected = 'WARNING:api.iam.models:Schema "eek01" already exists. Exit with False.'
        with self.assertLogs("api.iam.models", level="INFO") as _logger:
            Tenant.objects.create(schema_name="eek01").create_schema()
            self.assertIn(expected, _logger.output)

        # Verify that tenant record was created
        self.assertEqual(Tenant.objects.filter(schema_name="eek01").count(), 1)

        # Verify that no changes were made to existing schema
        with raw_conn.cursor() as cur:
            cur.execute("""select count(*) as ct from information_schema.tables where table_schema = 'eek01';""")
            res = cur.fetchone()[0]
            self.assertEqual(res, 1)

        # Verify that delete of tenant will also drop schema that existed
        Tenant.objects.filter(schema_name="eek01").delete()
        with raw_conn.cursor() as cur:
            cur.execute("""select count(*) from pg_namespace where nspname = 'eek01';""")
            res = cur.fetchone()[0]
            self.assertEqual(res, 0)

    def test_create_bad_tenant_name(self):
        """
        Test that creating a tenant with a bad name will throw an exception
        """
        with self.assertRaises(ValidationError):
            Tenant.objects.create(schema_name="bad schema-name")
