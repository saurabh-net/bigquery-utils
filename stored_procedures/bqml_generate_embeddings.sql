/*
 * Copyright 2024 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

-- Iteratively executes the BQML.GENERATE_EMBEDDING function to ensure all source table rows are embedded in the destination table, 
-- handling potential retryable errors gracefully along the way. 
-- Any rows already present in the destination table are ignored, so this procedure is safe to call multiple times.

-- @param STRING source_table : The full path of the BigQuery table containing the text data to be embedded. Path format - "project.dataset.table" or "dataset.table"
-- @param STRING target_table : The full path of the BigQuery table where the generated embeddings will be stored. This table will be created if it does not exist.
-- @param STRING ml_model : The full path of the embedding model to be used.
-- @param STRING content_column : The name of the column in the `source_table` containing the text to be embedded.
-- @param ARRAY<STRING> key_columns : An array of column names in the `source_table` that uniquely identify each row. '*' is not a valid value.
-- @param STRING options_string : A JSON string containing additional optional parameters for the embedding generation process. Set to '{}' if you want to use defaults for all options parameters.
-- @param STRING options : A JSON string containing optional parameters for the operation.
-- A sample fully-filled JSON option string would look like:
-- '{
--   "batch_size": 50000,
--   "termination_time_secs": 43200,  // 12 hours
--   "where_clause": "LENGTH(text) < 1000",
--   "projection_columns": ["type", "text"],
--   "ml_options": "STRUCT(FALSE AS flatten_json_output)"
-- }'

-- The parameters within the options string are documented below as:
-- @param INT64 batch_size : The number of rows to process in each child job during the procedure. A larger value will reduce the overhead of multiple child jobs, but needs to be small enough to complete in a single job run. Defaults to 80000.
-- @param INT64 termination_time_secs : The maximum time (in seconds) the script should run before terminating. Defaults to 82800 (23 hours).
-- @param STRING where_clause : An optional SQL WHERE clause to filter the rows from the source table before processing. Defaults to 'TRUE'.
-- @param ARRAY<STRING> projection_columns : An array of column names to select from the source table into the destination table. Defaults to all columns ('*').
-- @param STRING ml_options : A JSON string representing additional options for the ML operation. Defaults to 'STRUCT(TRUE AS flatten_json_output)' which flattens JSON output.
CREATE OR REPLACE PROCEDURE `bqutil.procedure.bqml_generate_embeddings`(source_table STRING, target_table STRING, ml_model STRING, content_column STRING, key_columns ARRAY<STRING>, options_string STRING)
BEGIN

DECLARE batch_size DEFAULT 80000;

-- The time to wait before the script terminates
DECLARE termination_time_secs DEFAULT(23 * 60 * 60);

-- An optional where clause to apply to the source table
DECLARE where_clause DEFAULT 'TRUE';

-- The columns to project from the source table to the target table
DECLARE projection_columns DEFAULT ARRAY['*'];

-- The ML options to use for the ML operation
DECLARE ml_options DEFAULT 'STRUCT(TRUE AS flatten_json_output)';


DECLARE
  ml_query
    DEFAULT
      FORMAT(
        'SELECT %s, %s AS content FROM `%s` WHERE %s',
        ARRAY_TO_STRING(projection_columns, ','),
        content_column,
        source_table,
        where_clause);

-- The filter condition for accepting the ML result into the target table
DECLARE
  accept_filter
    DEFAULT 'ml_generate_embedding_status' || " NOT LIKE 'A retryable error occurred:%'";

DECLARE
  key_cols_filter
    DEFAULT(
      SELECT
        STRING_AGG('S.' || KEY || ' = T.' || KEY, ' AND ')
      FROM
        UNNEST(key_columns) AS KEY
    );

DECLARE options JSON;

BEGIN
  SET options = PARSE_JSON(options_string);
EXCEPTION WHEN ERROR THEN
  RAISE USING MESSAGE = 'Unable to parse options_string as JSON';
END;

BEGIN
  IF JSON_EXTRACT_SCALAR(options, '$.batch_size') IS NOT NULL THEN
    SET batch_size = CAST(JSON_EXTRACT_SCALAR(options, '$.batch_size') AS INT64);
  END IF;
EXCEPTION WHEN ERROR THEN
  RAISE USING MESSAGE = 'Invalid batch_size. It must be an integer.';
END;

BEGIN
IF JSON_EXTRACT_SCALAR(options, '$.termination_time_secs') IS NOT NULL THEN
  SET termination_time_secs = CAST(JSON_EXTRACT_SCALAR(options, '$.termination_time_secs') AS INT64);
END IF;
EXCEPTION WHEN ERROR THEN
  RAISE USING MESSAGE = 'Invalid termination_time_secs. It must be an integer.';
END;

BEGIN
IF JSON_EXTRACT_SCALAR(options, '$.where_clause') IS NOT NULL THEN
  SET where_clause = CAST(JSON_EXTRACT_SCALAR(options, '$.where_clause') AS STRING);
END IF;
EXCEPTION WHEN ERROR THEN
  RAISE USING MESSAGE = 'Invalid where_clause. It must be a string.';
END;

BEGIN
IF JSON_EXTRACT_SCALAR(options, '$.projection_columns') IS NOT NULL THEN
  SET ml_options = JSON_EXTRACT_STRING_ARRAY(options, '$.projection_columns');
END IF;
EXCEPTION WHEN ERROR THEN
  RAISE USING MESSAGE = 'Invalid projection_columns. It must be an array of strings.';
END;

BEGIN
IF JSON_EXTRACT_SCALAR(options, '$.ml_options') IS NOT NULL THEN
  SET ml_options = CAST(JSON_EXTRACT_SCALAR(options, '$.ml_options') AS STRING);
END IF;
EXCEPTION WHEN ERROR THEN
  RAISE USING MESSAGE = 'Invalid ml_options. It must be a string.';
END;

SELECT source_table, target_table, ml_model, content_column, key_columns, options, batch_size, where_clause, termination_time_secs, projection_columns, ml_options;

-- Create the target table first if it does not exist
EXECUTE
  IMMEDIATE
    FORMAT(
      '''
CREATE TABLE IF NOT EXISTS `%s` AS
  (SELECT *
   FROM ML.GENERATE_EMBEDDING (MODEL `%s`,
           (SELECT *
            FROM (%s)
            LIMIT 10), %s)
   WHERE %s)''',
      target_table,
      ml_model,
      ml_query,
      ml_options,
      accept_filter);

-- Iteratively populate the target table
REPEAT
DROP TABLE IF EXISTS _SESSION.embedding_batch;

-- Identify new rows in the source table to generate embeddings
-- For throughput reasons, Materialize these rows into a temp table before calling GENERATE_EMBEDDING()
EXECUTE
  IMMEDIATE
    FORMAT(
      '''
      CREATE TEMP TABLE _SESSION.embedding_batch AS
      (SELECT *
          FROM (%s) AS S
          WHERE NOT EXISTS (SELECT * FROM %s AS T WHERE %s) LIMIT %d)
    ''',
      ml_query,
      target_table,
      key_cols_filter,
      batch_size);

-- Generate embeddings for these rows and insert them into the target table
EXECUTE
  IMMEDIATE
    FORMAT(
      '''
        INSERT `%s`
        SELECT *
            FROM ML.GENERATE_EMBEDDING (MODEL `%s`,
                    TABLE _SESSION.embedding_batch, %s)
            WHERE %s
        ''',
      target_table,
      ml_model,
      ml_options,
      accept_filter);

UNTIL(
  SELECT
    @@row_count
)
= 0
OR TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), @@script.creation_time, SECOND)
  >= termination_time_secs
    END
      REPEAT;
END