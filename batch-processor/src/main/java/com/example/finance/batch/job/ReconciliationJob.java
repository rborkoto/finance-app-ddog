package com.example.finance.batch.job;

import com.example.finance.batch.listener.JobSummaryListener;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.Job;
import org.springframework.batch.core.JobParameters;
import org.springframework.batch.core.JobParametersBuilder;
import org.springframework.batch.core.Step;
import org.springframework.batch.core.job.builder.JobBuilder;
import org.springframework.batch.core.launch.JobLauncher;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.item.ItemProcessor;
import org.springframework.batch.item.ItemWriter;
import org.springframework.batch.item.database.JdbcCursorItemReader;
import org.springframework.batch.item.database.builder.JdbcCursorItemReaderBuilder;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.transaction.PlatformTransactionManager;

import javax.sql.DataSource;
import java.time.LocalDate;
import java.util.HashMap;
import java.util.Map;

@Configuration
public class ReconciliationJob {

    private static final Logger log = LoggerFactory.getLogger(ReconciliationJob.class);

    private static final String JOB_NAME = "end-of-day-reconciliation";
    private static final int CHUNK_SIZE = 100;

    @Autowired
    private JobLauncher jobLauncher;

    @Autowired
    private JobRepository jobRepository;

    @Autowired
    private PlatformTransactionManager transactionManager;

    @Autowired
    private DataSource dataSource;

    @Autowired
    private JobSummaryListener jobSummaryListener;

    // ── SCHEDULER ─────────────────────────────────────────────────────────────
    // Uncomment the @Scheduled annotation to enable nightly execution.
    // Cron expression: "0 0 23 * * *" = every day at 23:00 UTC.
    // Requires @EnableScheduling on BatchProcessorApplication.
    // Set spring.batch.job.enabled=false to prevent auto-launch on startup.
    //
    // @Scheduled(cron = "${batch.reconciliation.cron:0 0 23 * * *}")
    // ─────────────────────────────────────────────────────────────────────────
    public void launchReconciliationJob() throws Exception {
        JobParameters params = new JobParametersBuilder()
                .addString("run.date", LocalDate.now().toString())
                .addLong("run.timestamp", System.currentTimeMillis()) // ensures uniqueness
                .toJobParameters();

        log.info("Launching reconciliation job for date={}", LocalDate.now());
        jobLauncher.run(reconciliationBatchJob(), params);
    }

    @Bean
    public Job reconciliationBatchJob() {
        return new JobBuilder(JOB_NAME, jobRepository)
                .listener(jobSummaryListener)
                .start(reconciliationStep())
                .build();
    }

    @Bean
    public Step reconciliationStep() {
        return new StepBuilder("reconciliation-step", jobRepository)
                .<Map<String, Object>, Map<String, Object>>chunk(CHUNK_SIZE, transactionManager)
                .reader(reconciliationItemReader())
                .processor(reconciliationItemProcessor())
                .writer(reconciliationItemWriter())
                .build();
    }

    @Bean
    public JdbcCursorItemReader<Map<String, Object>> reconciliationItemReader() {
        boolean scenarioEnabled = Boolean.parseBoolean(
                System.getenv().getOrDefault("RECONCILIATION_SCENARIO_ENABLED", "false"));
        String whereClause = "status = 'settled' AND settled_at >= CURRENT_DATE - INTERVAL '1 day'"
                + (scenarioEnabled ? " AND currency <> 'JPY'" : "");

        return new JdbcCursorItemReaderBuilder<Map<String, Object>>()
                .name("reconciliationItemReader")
                .dataSource(dataSource)
                .sql("""
                        SELECT id, account_id, amount, currency, status, settled_at
                        FROM transactions
                        WHERE %s
                        ORDER BY settled_at ASC
                        """.formatted(whereClause))
                .rowMapper((rs, rowNum) -> {
                    Map<String, Object> row = new HashMap<>();
                    row.put("id", rs.getString("id"));
                    row.put("account_id", rs.getString("account_id"));
                    row.put("amount", rs.getBigDecimal("amount"));
                    row.put("currency", rs.getString("currency"));
                    row.put("status", rs.getString("status"));
                    row.put("settled_at", rs.getTimestamp("settled_at"));
                    return row;
                })
                .build();
    }

    @Bean
    public ItemProcessor<Map<String, Object>, Map<String, Object>> reconciliationItemProcessor() {
        return item -> {
            // Stub: flag discrepancies — in production, compare with external ledger
            log.debug("Processing transaction id={} amount={} currency={}",
                    item.get("id"), item.get("amount"), item.get("currency"));

            item.put("reconciled", true);
            item.put("discrepancy", false);
            return item;
        };
    }

    // ── ITEM WRITER ───────────────────────────────────────────────────────────
    // Stub: writes reconciliation results to the discrepancy_report table.
    // ─────────────────────────────────────────────────────────────────────────
    @Bean
    public ItemWriter<Map<String, Object>> reconciliationItemWriter() {
        return chunk -> {
            log.info("Writing {} reconciliation records to discrepancy_report", chunk.size());
            // In production: batch INSERT into discrepancy_report table via JdbcBatchItemWriter
            // or flag and escalate discrepancies via the notification-service queue.
        };
    }
}
