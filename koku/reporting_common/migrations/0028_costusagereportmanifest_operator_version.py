# Generated by Django 3.1.12 on 2021-06-30 14:05
from django.db import migrations
from django.db import models


class Migration(migrations.Migration):

    dependencies = [("reporting_common", "0027_auto_20210412_1731")]

    operations = [
        migrations.AddField(
            model_name="costusagereportmanifest", name="operator_version", field=models.TextField(null=True)
        )
    ]
