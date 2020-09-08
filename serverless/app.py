import boto3
from botocore.exceptions import ClientError
import datetime
import logging
import json
import os
from slack import WebClient
from slack.errors import SlackApiError
import urllib.request, urllib.parse


logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


def get_param(client, param):
    try:
        response = client.get_parameter(
            Name=param,
            WithDecryption=True
        )
    except ClientError as e:
        logger.error(e)
        raise
    return response['Parameter']['Value']


def format_timestamp(timestamp):
    if timestamp.endswith('Z'):
        timestamp = f"{timestamp[:-1]}+00:00"
    timestamp = datetime.datetime.fromisoformat(timestamp)
    return timestamp.timestamp()


def is_json(myjson):
    try:
        json_object = json.loads(myjson)
    except ValueError as e:
        return False
    return True


def slack_color(state):
    slack_colors = {
        'OK': 'good',
        'INFO': '#2196F3',
        'INSUFFICIENT_DATA': 'warning',
        'WARNING': 'warning',
        'ALARM': 'danger',
        'ERROR': 'danger',
        'CRITICAL': 'danger'
    }
    return slack_colors[state]


def cloudwatch_handler(record):
    aws_region = record['Sns']['TopicArn'].split(':')[3]
    aws_account = record['Sns']['TopicArn'].split(':')[4]
    sns_message = record['Sns']['Message']
    sns_timestamp = record['Sns']['Timestamp']

    attachment = {
        'color': slack_color(sns_message['NewStateValue']),
        'fallback': '',
        'fields': [
            {
                'title': 'Alarm Name',
                'value': sns_message['AlarmName'],
                'short': True
            },
            {
                'title': 'Alarm Description',
                'value': sns_message['AlarmDescription'],
                'short': False
            },
            {
                'title': 'Alarm Reason',
                'value': sns_message['NewStateReason'],
                'short': False
            },
            {
                'title': 'Old State',
                'value': sns_message['OldStateValue'],
                'short': True
            },
            {
                'title': 'Current State',
                'value': sns_message['NewStateValue'],
                'short': True
            },
            {
                'title': 'Link to Alarm',
                'value': f"https://console.aws.amazon.com/cloudwatch/home?region={aws_region}#alarm:alarmFilter=ANY;name={urllib.parse.quote(sns_message['AlarmName'])}",
                'short': False
            }
        ],
        'ts': format_timestamp(sns_timestamp)
    }
    return attachment


def dms_handler(record):
    aws_region = record['Sns']['TopicArn'].split(':')[3]
    aws_account = record['Sns']['TopicArn'].split(':')[4]
    sns_message = record['Sns']['Message']
    attachment = {}

    if is_json(sns_message):
        sns_message = json.loads(sns_message)

    replication_instance_events = {
        'DMS-EVENT-0012': {'category': 'Configuration Change', 'severity': 'INFO'},
        'DMS-EVENT-0014': {'category': 'Configuration Change', 'severity': 'INFO'},
        'DMS-EVENT-0018': {'category': 'Configuration Change', 'severity': 'INFO'},
        'DMS-EVENT-0017': {'category': 'Configuration Change', 'severity': 'INFO'},
        'DMS-EVENT-0024': {'category': 'Configuration Change', 'severity': 'INFO'},
        'DMS-EVENT-0025': {'category': 'Configuration Change', 'severity': 'INFO'},
        'DMS-EVENT-0030': {'category': 'Configuration Change', 'severity': 'INFO'},
        'DMS-EVENT-0029': {'category': 'Configuration Change', 'severity': 'INFO'},
        'DMS-EVENT-0067': {'category': 'Creation', 'severity': 'INFO'},
        'DMS-EVENT-0005': {'category': 'Creation', 'severity': 'INFO'},
        'DMS-EVENT-0066': {'category': 'Deletion', 'severity': 'WARNING'},
        'DMS-EVENT-0003': {'category': 'Deletion', 'severity': 'WARNING'},
        'DMS-EVENT-0047': {'category': 'Maintenance', 'severity': 'INFO'},
        'DMS-EVENT-0026': {'category': 'Maintenance', 'severity': 'INFO'},
        'DMS-EVENT-0027': {'category': 'Maintenance', 'severity': 'INFO'},
        'DMS-EVENT-0068': {'category': 'Maintenance', 'severity': 'INFO'},
        'DMS-EVENT-0007': {'category': 'Low Storage', 'severity': 'WARNING'},
        'DMS-EVENT-0013': {'category': 'Failover', 'severity': 'WARNING'},
        'DMS-EVENT-0049': {'category': 'Failover', 'severity': 'WARNING'},
        'DMS-EVENT-0015': {'category': 'Failover', 'severity': 'WARNING'},
        'DMS-EVENT-0050': {'category': 'Failover', 'severity': 'WARNING'},
        'DMS-EVENT-0051': {'category': 'Failover', 'severity': 'WARNING'},
        'DMS-EVENT-0034': {'category': 'Failover', 'severity': 'WARNING'},
        'DMS-EVENT-0031': {'category': 'Failure', 'severity': 'CRITICAL'},
        'DMS-EVENT-0036': {'category': 'Failure', 'severity': 'CRITICAL'},
        'DMS-EVENT-0037': {'category': 'Failure', 'severity': 'CRITICAL'}
    }

    replication_task_events = {
        'DMS-EVENT-0069': {'category': 'State Change', 'severity': 'INFO'},
        'DMS-EVENT-0077': {'category': 'State Change', 'severity': 'INFO'},
        'DMS-EVENT-0081': {'category': 'State Change', 'severity': 'INFO'},
        'DMS-EVENT-0079': {'category': 'State Change', 'severity': 'WARNING'},
        'DMS-EVENT-0078': {'category': 'Failure', 'severity': 'CRITICAL'},
        'DMS-EVENT-0082': {'category': 'Failure', 'severity': 'CRITICAL'},
        'DMS-EVENT-0080': {'category': 'Configuration Change', 'severity': 'INFO'},
        'DMS-EVENT-0073': {'category': 'Deletion', 'severity': 'WARNING'},
        'DMS-EVENT-0074': {'category': 'Creation', 'severity': 'INFO'}
    }

    if isinstance(sns_message, dict):
        dms_event_source = sns_message['Event Source']
        dms_event_id = sns_message['Event ID'].split('#')[-1].strip()
        dms_timestamp = sns_message['Event Time']
    else:
        attachment = generic_handler(record, record['Sns']['Subject'])
        return attachment

    try:
        if dms_event_source == "replication-instance":
            event_meta = replication_instance_events[dms_event_id]
        elif dms_event_source == "replication-task":
            event_meta = replication_task_events[dms_event_id]
        else:
            logger.info(f"No defined logic for dms event source '{dms_event_source}'.")
            return attachment
    except KeyError:
        logger.info(f"No defined logic for dms event source '{dms_event_source}' id '{dms_event_id}'.")
        return attachment

    identifier_link, dms_source_id = sns_message['Identifier Link'].split('\nSourceId: ')

    if dms_event_source == "replication-instance":
        identifier_link = f"https://{aws_region}.console.aws.amazon.com/dms/v2/home?region={aws_region}#replicationInstanceDetails/{dms_source_id}"
    elif dms_event_source == "replication-task":
        identifier_link = f"https://{aws_region}.console.aws.amazon.com/dms/v2/home?region={aws_region}#taskDetails/{dms_source_id}"

    sns_message.update({'Identifier Link': identifier_link, 'SourceId': dms_source_id})
    source_type = ' '.join([s.capitalize() for s in dms_event_source.split('-')])
    source_type_short = source_type.replace('Replication ', '')

    attachment = {
        'color': slack_color(event_meta['severity']),
        'fallback': f"{event_meta['category']}: {dms_source_id} - {sns_message['Event Message']}",
        "title": f"DMS {source_type_short} {event_meta['category']} | {dms_source_id}",
        "title_link": identifier_link,
        'fields': [
            {
                'title': "Message",
                'value': sns_message['Event Message'],
                'short': False
            },
            {
                'title': 'Alarm State',
                'value': event_meta['severity'],
                'short': True
            },
            {
                'title': 'Event',
                'value': f"DMS {source_type} {event_meta['category']}",
                'short': True
            },
            {
                'title': 'Account',
                'value': aws_account,
                'short': True
            },
            {
                'title': 'Region',
                'value': aws_region,
                'short': True
            }
        ],
        'ts': format_timestamp(dms_timestamp)
    }
    return attachment


def emr_handler(record):
    attachment = {}

    try:
        sns_message = json.loads(record['Sns']['Message'])
    except ValueError:
        logger.error(f"Failed to decode sns message: {record['Sns']['Message']}")
        return attachment

    aws_account = sns_message['account']
    aws_region = sns_message['region']
    emr_timestamp = sns_message['time']
    emr_source_type = 'Step' if 'stepId' in sns_message['detail'] else 'Cluster'
    title_link = f"https://{aws_region}.console.aws.amazon.com/elasticmapreduce/home?region={aws_region}#cluster-details:{sns_message['detail']['clusterId']}"

    attachment = {
        'color': slack_color(sns_message['detail']['severity']),
        'fallback': sns_message['detail-type'],
        "title": f"{sns_message['detail-type']} | {sns_message['detail']['name']}",
        "title_link": title_link,
        'fields': [
            {
                'title': 'Message',
                'value': sns_message['detail']['message'],
                'short': False
            },
            {
                'title': 'Alarm State',
                'value': sns_message['detail']['severity'],
                'short': True
            },
            {
                'title': 'Event',
                'value': sns_message['detail-type'],
                'short': True
            },
            {
                'title': 'Source Type',
                'value': emr_source_type,
                'short': True
            },
            {
                'title': 'Cluster ID',
                'value': sns_message['detail']['clusterId'],
                'short': True
            },
            {
                'title': 'Account',
                'value': aws_account,
                'short': True
            },
            {
                'title': 'Region',
                'value': aws_region,
                'short': True
            }
        ],
        'ts': format_timestamp(emr_timestamp)
    }

    return attachment


def generic_handler(record, title="AWS Notification"):
    aws_region = record['Sns']['TopicArn'].split(':')[3]
    aws_account = record['Sns']['TopicArn'].split(':')[4]
    sns_message = record['Sns']['Message']
    sns_timestamp = record['Sns']['Timestamp']

    attachment = {
        'color': slack_color('INFO'),
        "title": title,
        'fields': [
            {
                'title': 'Message',
                'value': sns_message,
                'short': False
            },
            {
                'title': 'Account',
                'value': aws_account,
                'short': True
            },
            {
                'title': 'Region',
                'value': aws_region,
                'short': True
            }
        ],
        'ts': format_timestamp(sns_timestamp)
    }

    return attachment


def post_message(attachments):
    ssm_client = boto3.client('ssm')

    try:
        slack_bot_token_param = os.getenv('SLACK_BOT_TOKEN_PARAM')
        if slack_bot_token_param:
            slack_bot_token = get_param(ssm_client, slack_bot_token_param)
        else:
            slack_bot_token = os.environ['SLACK_BOT_TOKEN']

        slack_channel_param = os.getenv('SLACK_CHANNEL_PARAM')
        if slack_channel_param:
            slack_channel = get_param(ssm_client, slack_channel_param)
        else:
            slack_channel = os.environ['SLACK_CHANNEL']
    except KeyError as e:
        logger.error(f"Fallback environment variable not found: {e}")
        raise

    client = WebClient(token=slack_bot_token)

    try:
        response = client.chat_postMessage(
            channel=slack_channel,
            attachments=attachments
        )
    except SlackApiError as e:
        assert e.response['ok'] is False
        assert e.response['error']
        logger.error(f"Error connecting to Slack API: {e.response['error']}")
        raise

    if response.status_code < 400:
        logger.info('message posted successfully')
    elif response.status_code < 500:
        logger.error(f"Error posting message to Slack API: {response.status_code} - {response.data['message']}")

    return response.status_code


def process_record(record):
    slack_attachments = []
    sns_message = record['Sns']['Message']

    if is_json(sns_message):
        sns_message = json.loads(sns_message)

    if isinstance(sns_message, dict):
        # cloudwatch
        if all(i in sns_message for i in ['AlarmName', 'AlarmDescription']):
            attachment = cloudwatch_handler(record)
        # dms
        elif 'Subject' in record['Sns'] and record['Sns']['Subject'] == "DMS Notification Message":
            attachment = dms_handler(record)
        # emr
        elif 'source' in sns_message and sns_message['source'] == "aws.emr":
            attachment = emr_handler(record)
        # generic
        else:
            attachment = generic_handler(record)
    else:
        # dms
        if record['Sns']['Subject'] == "DMS Notification Message":
            attachment = dms_handler(record)
        # generic
        else:
            attachment = generic_handler(record)

    try:
        slack_attachments.append(attachment)
    except NameError as e:
        raise RuntimeError(f"Failed to process record: {record}") from e

    return post_message(slack_attachments)


def lambda_handler(event, context):
    """Sample pure Lambda function

    Parameters
    ----------
    event: dict, required
       SNS Message
       Event doc: https://docs.aws.amazon.com/lambda/latest/dg/with-sns.html

    context: object, required
        Lambda Context runtime methods and attributes
        Context doc: https://docs.aws.amazon.com/lambda/latest/dg/python-context-object.html
    """

    record, response = event['Records'][0], None

    if record['EventSource'] == "aws:sns":
        if record['Sns']['Type'] == 'Notification':
            response = process_record(record)
    else:
        logger.error(f"Unsupported EventSource format: {record['EventSource']}")

    return {'statusCode': response}