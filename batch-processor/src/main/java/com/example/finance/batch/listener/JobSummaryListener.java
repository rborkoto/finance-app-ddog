package com.example.finance.batch.listener;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.JobExecution;
import org.springframework.batch.core.JobExecutionListener;
import org.springframework.batch.core.StepExecution;
import org.springframework.stereotype.Component;

/**
 * Logs a one-line summary at the start and end of every batch job:
 * job name, status, and how many records were read, written and skipped.
 */
@Component
public class JobSummaryListener implements JobExecutionListener {

    private static final Logger log = LoggerFactory.getLogger(JobSummaryListener.class);

    @Override
    public void beforeJob(JobExecution jobExecution) {
        log.info("Batch job starting job.name={} job.id={} job.parameters={}",
                jobExecution.getJobInstance().getJobName(),
                jobExecution.getJobId(),
                jobExecution.getJobParameters());
    }

    @Override
    public void afterJob(JobExecution jobExecution) {
        String jobName = jobExecution.getJobInstance().getJobName();

        long written = jobExecution.getStepExecutions().stream()
                .mapToLong(StepExecution::getWriteCount)
                .sum();
        long read = jobExecution.getStepExecutions().stream()
                .mapToLong(StepExecution::getReadCount)
                .sum();
        long skipped = jobExecution.getStepExecutions().stream()
                .mapToLong(step -> step.getReadSkipCount()
                        + step.getProcessSkipCount()
                        + step.getWriteSkipCount())
                .sum();

        log.info("Batch job completed job.name={} job.status={} records.read={} records.written={} records.skipped={}",
                jobName, jobExecution.getStatus(), read, written, skipped);

        if (jobExecution.getStatus().isUnsuccessful()) {
            jobExecution.getAllFailureExceptions().forEach(ex ->
                    log.error("Batch job failure job.name={} error={}", jobName, ex.getMessage(), ex));
        }
    }
}
