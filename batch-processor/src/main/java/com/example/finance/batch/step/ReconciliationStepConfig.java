package com.example.finance.batch.step;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.Step;
import org.springframework.batch.core.StepContribution;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.scope.context.ChunkContext;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.core.step.tasklet.Tasklet;
import org.springframework.batch.repeat.RepeatStatus;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.PlatformTransactionManager;

import javax.sql.DataSource;
import java.util.Map;

/**
 * Spring Batch {@link Step} configuration for the End-of-Day Reconciliation job.
 *
 * <p>Placeholder for step-level configuration. The main chunk-oriented step
 * (reader → processor → writer) is defined in {@link ReconciliationJob}
 * (chunk size: 100).
 *
 * <p>A pre-flight validation tasklet that checks source data availability
 * before the main chunk processing begins can be added here.
 */
@Configuration
public class ReconciliationStepConfig {

    private static final Logger log = LoggerFactory.getLogger(ReconciliationStepConfig.class);

    private static final int CHUNK_SIZE = 100;

    @Autowired
    private JobRepository jobRepository;

    @Autowired
    private PlatformTransactionManager transactionManager;

    @Autowired
    private DataSource dataSource;

    // ── PREFLIGHT TASKLET STEP ────────────────────────────────────────────────
    // Validates that the transactions table has data for the current run date
    // before committing to the full chunk-processing step.
    //
    // @Bean
    // public Step reconciliationPreflightStep() {
    //     return new StepBuilder("reconciliation-preflight-step", jobRepository)
    //             .tasklet(preflightTasklet(), transactionManager)
    //             .build();
    // }
    //
    // @Bean
    // public Tasklet preflightTasklet() {
    //     return new Tasklet() {
    //         @Override
    //         public RepeatStatus execute(StepContribution contribution,
    //                                     ChunkContext chunkContext) {
    //             log.info("Preflight validation: checking transaction data availability");
    //             // TODO: SELECT COUNT(*) FROM transactions WHERE status='settled' AND settled_at >= CURRENT_DATE
    //             // If count == 0, throw exception to fail fast before chunk processing.
    //             return RepeatStatus.FINISHED;
    //         }
    //     };
    // }
    // ─────────────────────────────────────────────────────────────────────────

}
