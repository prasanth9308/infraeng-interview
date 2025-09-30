"""
Lambda that calls StartInstanceRefresh on a given AutoScaling Group.
Event payload expected: { "AutoScalingGroupName": "my-asg" }
"""
import json
import os
import boto3

client = boto3.client("autoscaling")

def lambda_handler(event, context):
    asg_name = event.get("AutoScalingGroupName")
    if not asg_name:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "AutoScalingGroupName missing"})
        }

    response = client.start_instance_refresh(
        AutoScalingGroupName=asg_name,
        Strategy='Rolling',
        Preferences={
            'MinHealthyPercentage': 90,
            'InstanceWarmup': 120
        }
    )
    return {
        "statusCode": 200,
        "body": json.dumps(response)
    }
