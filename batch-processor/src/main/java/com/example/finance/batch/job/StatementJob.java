package com.example.finance.batch.job;

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
import java.time.YearMonth;
import java.util.HashMap;
import java.util.Map;

/**
 * Spring Batch configuration for the Monthly Statement Generation Job.
 *
 * <p>Reads account history for the previous calendar month from the
 * {@code account_transactions} view, generates a PDF statement stub
 * per account, and records statement metadata in the {@code statements} table.
 *
 * <p>Scheduled to run on the 1st of each month at 01:00 UTC
 * (configurable in application.yml).
 *
 * <p>JobParameters include {@code statement.period} (YYYY-MM) to make each
 * monthly run uniquely identifiable — required for Spring Batch's
 * {@code JobInstanceAlreadyCompleteException} safeguard.
 *
 * <p>Chunk size: 50 (lower than ReconciliationJob — each item triggers
 * a heavier PDF-generation stub). Tune based on heap profiling results.
 */
@Configuration
public class StatementJob {

    private static final Logger log = LoggerFactory.getLogger(StatementJob.class);

    private static final String JOB_NAME = "monthly-statement-generation";
    private static final int CHUNK_SIZE = 50;

    @Autowired
    private JobLauncher jobLauncher;

    @Autowired
    private JobRepository jobRepository;

    @Autowired
    private PlatformTransactionManager transactionManager;

    @Autowired
    private DataSource dataSource;

    // ── SCHEDULER ─────────────────────────────────────────────────────────────
    // Uncomment the @Scheduled annotation to enable monthly execution.
    // Cron: "0 0 1 1 * *" = 1st day of every month at 01:00 UTC.
    // Requires @EnableScheduling on BatchProcessorApplication.
    //
    // @Scheduled(cron = "${batch.statement.cron:0 0 1 1 * *}")
    // ─────────────────────────────────────────────────────────────────────────
    public void launchStatementJob() throws Exception {
        YearMonth previousMonth = YearMonth.now().minusMonths(1);
        JobParameters params = new JobParametersBuilder()
                .addString("statement.period", previousMonth.toString()) // e.g. "2025-05"
                .addLong("run.timestamp", System.currentTimeMillis())
                .toJobParameters();

        log.info("Launching statement generation job for period={}", previousMonth);
        jobLauncher.run(statementBatchJob(), params);
    }

    @Bean
    public Job statementBatchJob() {
        return new JobBuilder(JOB_NAME, jobRepository)
                .start(statementStep())
                .build();
    }

    // ── STEP ─────────────────────────────────────────────────────────────────
    @Bean
    public Step statementStep() {
        return new StepBuilder("statement-step", jobRepository)
                .<Map<String, Object>, Map<String, Object>>chunk(CHUNK_SIZE, transactionManager)
                .reader(statementItemReader())
                .processor(statementItemProcessor())
                .writer(statementItemWriter())
                .build();
    }

    // ── ITEM READER ───────────────────────────────────────────────────────────
    // Reads distinct accounts that had activity in the previous calendar month.
    // Each item represents one account; the processor fetches full history.
    //
    // Ensure account_id is indexed in account_transactions and that the date
    // range predicate hits a partition or index.
    // ─────────────────────────────────────────────────────────────────────────
    @Bean
    public JdbcCursorItemReader<Map<String, Object>> statementItemReader() {
        return new JdbcCursorItemReaderBuilder<Map<String, Object>>()
                .name("statementItemReader")
                .dataSource(dataSource)
                .sql("""
                        SELECT DISTINCT account_id, account_tier, currency
                        FROM account_transactions
                        WHERE transaction_date >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')
                          AND transaction_date <  DATE_TRUNC('month', CURRENT_DATE)
                        ORDER BY account_id ASC
                        """)
                .rowMapper((rs, rowNum) -> {
                    Map<String, Object> row = new HashMap<>();
                    row.put("account_id", rs.getString("account_id"));
                    row.put("account_tier", rs.getString("account_tier")); // retail | premium | corporate
                    row.put("currency", rs.getString("currency"));
                    return row;
                })
                .build();
    }

    // ── ITEM PROCESSOR ────────────────────────────────────────────────────────
    // Stub: generates a PDF statement for each account.
    // In production, this would call a PDF generation library or external service.
    //
    // Performance note: PDF generation is CPU-intensive.
    // ─────────────────────────────────────────────────────────────────────────
    @Bean
    public ItemProcessor<Map<String, Object>, Map<String, Object>> statementItemProcessor() {
        return item -> {
            String accountId = (String) item.get("account_id");
            String accountTier = (String) item.get("account_tier");

            log.debug("Generating statement for account_tier={} currency={}",
                    accountTier, item.get("currency"));

            // Stub: simulate PDF generation
            item.put("statement_generated", true);
            item.put("statement_path", "/statements/stub-" + accountTier + ".pdf");
            return item;
        };
    }

    // ── ITEM WRITER ───────────────────────────────────────────────────────────
    // Stub: records statement metadata in the statements table and enqueues
    // a notification to the alert.queue via the notification-service.
    //
    // ⚠ JMS PII NOTE: Never place account IDs or statement content in JMS
    // message bodies. Send only the statement_id reference; the consumer
    // resolves content from the DB.
    // ─────────────────────────────────────────────────────────────────────────
    @Bean
    public ItemWriter<Map<String, Object>> statementItemWriter() {
        return chunk -> {
            log.info("Writing {} statement records to statements table", chunk.size());
            // In production:
            //   1. JdbcBatchItemWriter → INSERT INTO statements (account_id, period, path)
            //   2. JmsTemplate.send("alert.queue", statementReadyMessage)
        };
    }
}
