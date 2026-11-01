# Alerting on Container Insights metrics (installed by the eks module). The ALB
# is owned by the Load Balancer Controller, so ALB 5xx/latency alarms are added
# once its name is known (see ARCHITECTURE.md follow-ups).

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "sns_key" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarmsPublish"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "sns" {
  description             = "Encrypts the ${var.name} alerts topic"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.sns_key.json
}

resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-alerts"
  kms_master_key_id = aws_kms_key.sns.arn
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "failed_nodes" {
  alarm_name          = "${var.cluster_name}-failed-nodes"
  alarm_description   = "One or more EKS nodes are failing."
  namespace           = "ContainerInsights"
  metric_name         = "cluster_failed_node_count"
  dimensions          = { ClusterName = var.cluster_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "node_cpu" {
  alarm_name          = "${var.cluster_name}-node-cpu-high"
  alarm_description   = "Average node CPU is high; the cluster may need more capacity."
  namespace           = "ContainerInsights"
  metric_name         = "node_cpu_utilization"
  dimensions          = { ClusterName = var.cluster_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "service_pods" {
  alarm_name        = "${var.cluster_name}-${var.service_name}-running-pods-low"
  alarm_description = "Fewer than ${var.min_running_pods} pods are running for ${var.service_name}."
  namespace         = "ContainerInsights"
  metric_name       = "service_number_of_running_pods"
  dimensions = {
    ClusterName = var.cluster_name
    Namespace   = var.service_namespace
    Service     = var.service_name
  }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  threshold           = var.min_running_pods
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
