package com.example.finance.batch;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * Finance Sample App — Batch Processor
 *
 * <p>Runs two scheduled Spring Batch jobs:
 * <ul>
 *   <li>{@code ReconciliationJob} — nightly end-of-day settlement reconciliation</li>
 *   <li>{@code StatementJob}      — monthly account statement generation</li>
 * </ul>
 */
@SpringBootApplication
@EnableScheduling
public class BatchProcessorApplication {

    public static void main(String[] args) {
        // Spring Batch auto-runs jobs on startup by default.
        // Set spring.batch.job.enabled=false in application.yml to disable
        // and rely on the @Scheduled triggers instead.
        SpringApplication.run(BatchProcessorApplication.class, args);
    }
}
