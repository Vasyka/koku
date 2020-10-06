# Generated by Django 3.1.2 on 2020-10-05 19:29
import uuid

import django.db.models.deletion
import tenant_schemas.postgresql_backend.base
from django.db import migrations
from django.db import models


class Migration(migrations.Migration):

    initial = True

    replaces = [
        ("api", "0001_initial_squashed_0008_auto_20190305_2015"),
        ("api", "0009_providerstatus_squashed_0042_auto_20200116_2048"),
        ("api", "0010_auto_20200128_2138"),
        ("api", "0011_auto_20200204_1647"),
        ("api", "0012_auto_20200225_2022"),
        ("api", "0013_auto_20200226_1953"),
        ("api", "0014_reload_azure_map"),
        ("api", "0015_auto_20200311_2049"),
        ("api", "0016_auto_20200324_1420"),
        ("api", "0017_delete_cloudaccount"),
        ("api", "0018_auto_20200326_0102"),
        ("api", "0019_delete_costmodelmetricsmap"),
        ("api", "0020_sources_out_of_order_delete"),
        ("api", "0021_delete_providerstatus"),
        ("api", "0022_auto_20200812_1945"),
        ("api", "0023_auto_20200820_2314"),
        ("api", "0024_auto_20200824_1759"),
        ("api", "0025_db_functions"),
        ("api", "0026_provider_data_updated_timestamp"),
        ("api", "0027_customer_date_updated"),
        ("api", "0028_public_function_update"),
        ("api", "0029_auto_20200921_2016"),
    ]

    dependencies = []

    operations = [
        migrations.CreateModel(
            name="Customer",
            fields=[
                ("id", models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("date_created", models.DateTimeField(auto_now_add=True)),
                ("date_updated", models.DateTimeField(auto_now_add=True)),
                ("uuid", models.UUIDField(default=uuid.uuid4, editable=False, unique=True)),
                ("account_id", models.CharField(max_length=150, null=True, unique=True)),
                ("schema_name", models.TextField(default="public", unique=True)),
            ],
            options={"ordering": ["schema_name"]},
        ),
        migrations.CreateModel(
            name="Provider",
            fields=[
                ("uuid", models.UUIDField(default=uuid.uuid4, primary_key=True, serialize=False)),
                ("name", models.CharField(max_length=256)),
                (
                    "type",
                    models.CharField(
                        choices=[
                            ("AWS", "AWS"),
                            ("OCP", "OCP"),
                            ("Azure", "Azure"),
                            ("GCP", "GCP"),
                            ("AWS-local", "AWS-local"),
                            ("Azure-local", "Azure-local"),
                            ("GCP-local", "GCP-local"),
                        ],
                        default="AWS",
                        max_length=50,
                    ),
                ),
                ("setup_complete", models.BooleanField(default=False)),
                ("created_timestamp", models.DateTimeField(auto_now_add=True, null=True)),
                ("data_updated_timestamp", models.DateTimeField(null=True)),
                ("active", models.BooleanField(default=True)),
            ],
            options={"ordering": ["name"]},
        ),
        migrations.CreateModel(
            name="ProviderAuthentication",
            fields=[
                ("id", models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("uuid", models.UUIDField(default=uuid.uuid4, editable=False, unique=True)),
                ("credentials", models.JSONField(default=dict)),
            ],
        ),
        migrations.CreateModel(
            name="ProviderBillingSource",
            fields=[
                ("id", models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("uuid", models.UUIDField(default=uuid.uuid4, editable=False, unique=True)),
                ("data_source", models.JSONField(default=dict)),
            ],
        ),
        migrations.CreateModel(
            name="Sources",
            fields=[
                ("source_id", models.IntegerField(primary_key=True, serialize=False)),
                ("source_uuid", models.UUIDField(null=True, unique=True)),
                ("name", models.CharField(max_length=256, null=True)),
                ("auth_header", models.TextField(null=True)),
                ("offset", models.IntegerField()),
                ("endpoint_id", models.IntegerField(null=True)),
                ("account_id", models.CharField(max_length=150, null=True)),
                ("source_type", models.CharField(max_length=50)),
                ("authentication", models.JSONField(default=dict)),
                ("billing_source", models.JSONField(default=dict, null=True)),
                ("koku_uuid", models.CharField(max_length=512, null=True, unique=True)),
                ("pending_delete", models.BooleanField(default=False)),
                ("pending_update", models.BooleanField(default=False)),
                ("out_of_order_delete", models.BooleanField(default=False)),
                ("status", models.JSONField(default=dict, null=True)),
            ],
            options={"db_table": "api_sources", "ordering": ["name"]},
        ),
        migrations.CreateModel(
            name="Tenant",
            fields=[
                ("id", models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                (
                    "schema_name",
                    models.CharField(
                        max_length=63,
                        unique=True,
                        validators=[tenant_schemas.postgresql_backend.base._check_schema_name],
                    ),
                ),
            ],
            options={"abstract": False},
        ),
        migrations.CreateModel(
            name="User",
            fields=[
                ("id", models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("uuid", models.UUIDField(default=uuid.uuid4, editable=False, unique=True)),
                ("username", models.CharField(max_length=150, unique=True)),
                ("email", models.EmailField(blank=True, max_length=254)),
                ("date_created", models.DateTimeField(auto_now_add=True)),
                ("is_active", models.NullBooleanField(default=True)),
                (
                    "customer",
                    models.ForeignKey(null=True, on_delete=django.db.models.deletion.CASCADE, to="api.customer"),
                ),
            ],
            options={"ordering": ["username"]},
        ),
        migrations.CreateModel(
            name="ProviderInfrastructureMap",
            fields=[
                ("id", models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                (
                    "infrastructure_type",
                    models.CharField(
                        choices=[
                            ("AWS", "AWS"),
                            ("Azure", "Azure"),
                            ("GCP", "GCP"),
                            ("AWS-local", "AWS-local"),
                            ("Azure-local", "Azure-local"),
                            ("GCP-local", "GCP-local"),
                        ],
                        max_length=50,
                    ),
                ),
                (
                    "infrastructure_provider",
                    models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, to="api.provider"),
                ),
            ],
        ),
        migrations.AddField(
            model_name="provider",
            name="authentication",
            field=models.ForeignKey(
                null=True, on_delete=django.db.models.deletion.DO_NOTHING, to="api.providerauthentication"
            ),
        ),
        migrations.AddField(
            model_name="provider",
            name="billing_source",
            field=models.ForeignKey(
                blank=True, null=True, on_delete=django.db.models.deletion.DO_NOTHING, to="api.providerbillingsource"
            ),
        ),
        migrations.AddField(
            model_name="provider",
            name="created_by",
            field=models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, to="api.user"),
        ),
        migrations.AddField(
            model_name="provider",
            name="customer",
            field=models.ForeignKey(null=True, on_delete=django.db.models.deletion.PROTECT, to="api.customer"),
        ),
        migrations.AddField(
            model_name="provider",
            name="infrastructure",
            field=models.ForeignKey(
                null=True, on_delete=django.db.models.deletion.SET_NULL, to="api.providerinfrastructuremap"
            ),
        ),
        migrations.CreateModel(
            name="DataExportRequest",
            fields=[
                ("id", models.AutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("uuid", models.UUIDField(default=uuid.uuid4, editable=False, unique=True)),
                ("created_timestamp", models.DateTimeField(auto_now_add=True)),
                ("updated_timestamp", models.DateTimeField(auto_now=True)),
                (
                    "status",
                    models.CharField(
                        choices=[
                            ("pending", "Pending"),
                            ("processing", "Processing"),
                            ("waiting", "Waiting"),
                            ("complete", "Complete"),
                            ("error", "Error"),
                        ],
                        default="pending",
                        max_length=32,
                    ),
                ),
                ("start_date", models.DateField()),
                ("end_date", models.DateField()),
                ("bucket_name", models.CharField(max_length=63)),
                ("created_by", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, to="api.user")),
            ],
            options={"ordering": ("created_timestamp",)},
        ),
        migrations.AlterUniqueTogether(
            name="provider", unique_together={("authentication", "billing_source", "customer")}
        ),
    ]