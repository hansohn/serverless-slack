import pytest
from serverless import app


@pytest.fixture()
def sns_event():
    """ Generates SNS DMS Event"""

    return {
        "Records": [
            {
                "EventSource": "aws:sns",
                "EventSubscriptionArn": "arn:aws:sns:us-east-2:123456789012:test-preprod-notifications:81991488-633a-4a59-804a-f2017597409e",
                "EventVersion": "1.0",
                "Sns": {
                    "Message": "{\"Event Source\":\"replication-task\",\"Event Time\":\"2020-08-12 04:38:53.303\",\"Identifier Link\":\"https://console.aws.amazon.com/dms/home?region=us-east-2#tasks:ids=test-preprod-source-127.0.0.1-database-table-kinesis\\nSourceId: test-preprod-source-127.0.0.1-database-table-kinesis \",\"Event ID\":\"http://docs.aws.amazon.com/dms/latest/userguide/CHAP_Events.html#DMS-EVENT-0069 \",\"Event Message\":\"Replication task has started.\"}",
                    "MessageAttributes": {},
                    "MessageId": "4a68a371-94a8-50bd-9410-f4dc15503b0e",
                    "Signature": "sVWyWhxOK4hSDkExFxrcX2nLD4d7sWIrBKSXhtVIui9XriFPWAbgmZ3jkUKvKogf2/8cuwL3CcsHRO5JYtUkbkHBUAfA2Llvp7LF9ekQeZXKrMlciNP356s89aoG5f6Aq3RFvKJ3doOwNRMYxEaXabwaqFIRIBKhNvVbqGJ8GckFthYJSMMg6MD8EXl7AU9iPXLUbxMkkxZ2XlqUPMeCrvEDSnWmp3Kmn499XVxNbdSxxjt5Vb7+JNlBicVgX40LEbG0mglJVJhC/+9Slh6nsr2v7SGG7YQdnP1/V+kLuR14BzImr/x0d6QtXc+vokaBbcvhK2XOPw5vi9ECaV4Kng==",
                    "SignatureVersion": "1",
                    "SigningCertUrl": "https://sns.us-east-2.amazonaws.com/SimpleNotificationService-a86cb10b4e1f29c941702d737128f7b6.pem",
                    "Subject": "DMS Notification Message",
                    "Timestamp": "2020-08-12T05:35:52.500Z",
                    "TopicArn": "arn:aws:sns:us-east-2:123456789012:test-preprod-notifications",
                    "Type": "Notification",
                    "UnsubscribeUrl": "https://sns.us-east-2.amazonaws.com/?Action=Unsubscribe&SubscriptionArn=arn:aws:sns:us-east-2:123456789012:test-preprod-notifications:81991488-633a-4a59-804a-f2017597409e"
                }
            }
        ]
    }


def test_lambda_handler(sns_event, mocker):
    ret = app.lambda_handler(sns_event, "")
    assert ret["statusCode"] == 200
