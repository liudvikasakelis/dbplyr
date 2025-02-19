#' Backend: PostgreSQL
#'
#' @description
#' See `vignette("translation-function")` and `vignette("translation-verb")` for
#' details of overall translation technology. Key differences for this backend
#' are:
#'
#' * Many stringr functions
#' * lubridate date-time extraction functions
#' * More standard statistical summaries
#'
#' Use `simulate_postgres()` with `lazy_frame()` to see simulated SQL without
#' converting to live access database.
#'
#' @name backend-postgres
#' @aliases NULL
#' @examples
#' library(dplyr, warn.conflicts = FALSE)
#'
#' lf <- lazy_frame(a = TRUE, b = 1, c = 2, d = "z", con = simulate_postgres())
#' lf %>% summarise(x = sd(b, na.rm = TRUE))
#' lf %>% summarise(y = cor(b, c), z = cov(b, c))
NULL

#' @include verb-copy-to.R
NULL

#' @export
#' @rdname backend-postgres
simulate_postgres <- function() simulate_dbi("PqConnection")

#' @export
dbplyr_edition.PostgreSQL <- function(con) {
  2L
}
#' @export
dbplyr_edition.PqConnection <- dbplyr_edition.PostgreSQL

#' @export
db_connection_describe.PqConnection <- function(con, ...) {
  info <- dbGetInfo(con)
  host <- if (info$host == "") "localhost" else info$host

  paste0("postgres ", info$serverVersion, " [", info$username, "@",
    host, ":", info$port, "/", info$dbname, "]")
}
#' @export
db_connection_describe.PostgreSQL <- db_connection_describe.PqConnection

postgres_grepl <- function(pattern,
                           x,
                           ignore.case = FALSE,
                           perl = FALSE,
                           fixed = FALSE,
                           useBytes = FALSE) {
  # https://www.postgresql.org/docs/current/static/functions-matching.html#FUNCTIONS-POSIX-TABLE
  check_unsupported_arg(perl, FALSE, backend = "PostgreSQL")
  check_unsupported_arg(fixed, FALSE, backend = "PostgreSQL")
  check_unsupported_arg(useBytes, FALSE, backend = "PostgreSQL")
  check_bool(ignore.case)

  if (ignore.case) {
    sql_expr(((!!x)) %~*% ((!!pattern)))
  } else {
    sql_expr(((!!x)) %~% ((!!pattern)))
  }
}
postgres_round <- function(x, digits = 0L) {
  digits <- as.integer(digits)
  sql_expr(round(((!!x)) %::% numeric, !!digits))
}

postgres_period <- function(x, unit) {
  x <- escape(x, con = sql_current_con())
  interval <- paste0(x, " ", unit)
  sql_expr(CAST(!!interval %AS% INTERVAL))
}

#' @export
sql_translation.PqConnection <- function(con) {
  sql_variant(
    sql_translator(.parent = base_scalar,
      bitwXor = sql_infix("#"),
      log10  = function(x) sql_expr(log(!!x)),
      log    = sql_log(),
      cot    = sql_cot(),
      round  = postgres_round,
      grepl  = postgres_grepl,

      paste  = sql_paste(" "),
      paste0 = sql_paste(""),

      # stringr functions
      # https://www.postgresql.org/docs/9.1/functions-string.html
      # https://www.postgresql.org/docs/9.1/functions-matching.html#FUNCTIONS-POSIX-REGEXP
      str_c = sql_paste(""),

      str_locate  = function(string, pattern) {
        sql_expr(strpos(!!string, !!pattern))
      },
      # https://www.postgresql.org/docs/9.1/functions-string.html
      str_detect = function(string, pattern, negate = FALSE) {
        sql_str_pattern_switch(
          string = string,
          pattern = {{ pattern }},
          negate = negate,
          f_fixed = sql_str_detect_fixed_position("detect"),
          f_regex = function(string, pattern, negate = FALSE) {
            if (isTRUE(negate)) {
              sql_expr(!(!!string ~ !!pattern))
            } else {
              sql_expr(!!string ~ !!pattern)
            }
          }
        )
      },
      str_ends = function(string, pattern, negate = FALSE) {
        sql_str_pattern_switch(
          string = string,
          pattern = {{ pattern }},
          negate = negate,
          f_fixed = sql_str_detect_fixed_position("end")
        )
      },
      # https://www.postgresql.org/docs/current/functions-matching.html
      str_like = function(string, pattern, ignore_case = TRUE) {
        check_bool(ignore_case)
        if (isTRUE(ignore_case)) {
          sql_expr(!!string %ILIKE% !!pattern)
        } else {
          sql_expr(!!string %LIKE% !!pattern)
        }
      },
      str_replace = function(string, pattern, replacement){
        sql_expr(regexp_replace(!!string, !!pattern, !!replacement))
      },
      str_replace_all = function(string, pattern, replacement){
        sql_expr(regexp_replace(!!string, !!pattern, !!replacement, 'g'))
      },
      str_squish = function(string){
        sql_expr(ltrim(rtrim(regexp_replace(!!string, '\\s+', ' ', 'g'))))
      },
      str_remove = function(string, pattern){
        sql_expr(regexp_replace(!!string, !!pattern, ''))
      },
      str_remove_all = function(string, pattern){
        sql_expr(regexp_replace(!!string, !!pattern, '', 'g'))
      },
      str_starts = function(string, pattern, negate = FALSE) {
        sql_str_pattern_switch(
          string = string,
          pattern = {{ pattern }},
          negate = negate,
          f_fixed = sql_str_detect_fixed_position("start")
        )
      },

      # lubridate functions
      # https://www.postgresql.org/docs/9.1/functions-datetime.html
      day = function(x) {
        sql_expr(EXTRACT(DAY %FROM% !!x))
      },
      mday = function(x) {
        sql_expr(EXTRACT(DAY %FROM% !!x))
      },
      wday = function(x, label = FALSE, abbr = TRUE, week_start = NULL) {
        check_bool(label)
        check_bool(abbr)
        check_number_whole(week_start, allow_null = TRUE)
        if (!label) {
          week_start <- week_start %||% getOption("lubridate.week.start", 7)
          offset <- as.integer(7 - week_start)
          sql_expr(EXTRACT("dow" %FROM% DATE(!!x) + !!offset) + 1)
        } else if (label && !abbr) {
          sql_expr(TO_CHAR(!!x, "Day"))
        } else if (label && abbr) {
          sql_expr(SUBSTR(TO_CHAR(!!x, "Day"), 1, 3))
        } else {
          cli_abort("Unrecognized arguments to {.arg wday}")
        }
      },
      yday = function(x) sql_expr(EXTRACT(DOY %FROM% !!x)),
      week = function(x) {
        sql_expr(FLOOR ((EXTRACT(DOY %FROM% !!x) - 1L) / 7L) + 1L)
      },
      isoweek = function(x) {
        sql_expr(EXTRACT(WEEK %FROM% !!x))
      },
      month = function(x, label = FALSE, abbr = TRUE) {
        check_bool(label)
        check_bool(abbr)
        if (!label) {
          sql_expr(EXTRACT(MONTH %FROM% !!x))
        } else {
          if (abbr) {
            sql_expr(TO_CHAR(!!x, "Mon"))
          } else {
            sql_expr(TO_CHAR(!!x, "Month"))
          }
        }
      },
      quarter = function(x, with_year = FALSE, fiscal_start = 1) {
        check_bool(with_year)
        check_unsupported_arg(fiscal_start, 1, backend = "PostgreSQL")

        if (with_year) {
          sql_expr((EXTRACT(YEAR %FROM% !!x) || '.' || EXTRACT(QUARTER %FROM% !!x)))
        } else {
          sql_expr(EXTRACT(QUARTER %FROM% !!x))
        }
      },
      isoyear = function(x) {
        sql_expr(EXTRACT(YEAR %FROM% !!x))
      },

      # https://www.postgresql.org/docs/13/datatype-datetime.html#DATATYPE-INTERVAL-INPUT
      seconds = function(x) {
        postgres_period(x, "seconds")
      },
      minutes = function(x) {
        postgres_period(x, "minutes")
      },
      hours = function(x) {
        postgres_period(x, "hours")
      },
      days = function(x) {
        postgres_period(x, "days")
      },
      weeks = function(x) {
        postgres_period(x, "weeks")
      },
      months = function(x) {
        postgres_period(x, "months")
      },
      years = function(x) {
        postgres_period(x, "years")
      },

      # https://www.postgresql.org/docs/current/functions-datetime.html#FUNCTIONS-DATETIME-TRUNC
      floor_date = function(x, unit = "seconds") {
        unit <- arg_match(unit,
          c("second", "minute", "hour", "day", "week", "month", "quarter", "year")
        )
        sql_expr(DATE_TRUNC(!!unit, !!x))
      },

      # clock ---------------------------------------------------------------
      add_days = function(x, n, ...) {
        check_dots_empty()
        glue_sql2(sql_current_con(), "({.col x} + {.val n}*INTERVAL'1 day')")
      },
      add_years = function(x, n, ...) {
        check_dots_empty()
        glue_sql2(sql_current_con(), "({.col x} + {.val n}*INTERVAL'1 year')")
      },
      date_build = function(year, month = 1L, day = 1L, ..., invalid = NULL) {
        check_unsupported_arg(invalid, allow_null = TRUE)
        sql_expr(make_date(!!year, !!month, !!day))
      },
      date_count_between = function(start, end, precision, ..., n = 1L){

        check_dots_empty()
        check_unsupported_arg(precision, allowed = "day")
        check_unsupported_arg(n, allowed = 1L)

        sql_expr(!!end - !!start)
      },
      get_year = function(x) {
        sql_expr(date_part('year', !!x))
      },
      get_month = function(x) {
        sql_expr(date_part('month', !!x))
      },
      get_day = function(x) {
        sql_expr(date_part('day', !!x))
      },

      difftime = function(time1, time2, tz, units = "days") {

        check_unsupported_arg(tz)
        check_unsupported_arg(units, allowed = "days")

        sql_expr((CAST(!!time1 %AS% DATE) - CAST(!!time2 %AS% DATE)))
      },
    ),
    sql_translator(.parent = base_agg,
      cor = sql_aggregate_2("CORR"),
      cov = sql_aggregate_2("COVAR_SAMP"),
      sd = sql_aggregate("STDDEV_SAMP", "sd"),
      var = sql_aggregate("VAR_SAMP", "var"),
      all = sql_aggregate("BOOL_AND", "all"),
      any = sql_aggregate("BOOL_OR", "any"),
      str_flatten = function(x, collapse = "") {
        sql_expr(string_agg(!!x, !!collapse))
      }
    ),
    sql_translator(.parent = base_win,
      cor = win_aggregate_2("CORR"),
      cov = win_aggregate_2("COVAR_SAMP"),
      sd =  win_aggregate("STDDEV_SAMP"),
      var = win_aggregate("VAR_SAMP"),
      all = win_aggregate("BOOL_AND"),
      any = win_aggregate("BOOL_OR"),
      str_flatten = function(x, collapse = "") {
        win_over(
          sql_expr(string_agg(!!x, !!collapse)),
          partition = win_current_group(),
          order = win_current_order()
        )
      },
      median = sql_win_not_supported("median", "PostgreSQL"),
      quantile = sql_win_not_supported("quantile", "PostgreSQL")
    )
  )
}
#' @export
sql_translation.PostgreSQL <- sql_translation.PqConnection

#' @export
sql_expr_matches.PqConnection <- function(con, x, y, ...) {
  # https://www.postgresql.org/docs/current/functions-comparison.html
  glue_sql2(con, "{x} IS NOT DISTINCT FROM {y}")
}
#' @export
sql_expr_matches.PostgreSQL <- sql_expr_matches.PqConnection

# http://www.postgresql.org/docs/9.3/static/sql-explain.html
#' @export
sql_query_explain.PqConnection <- function(con, sql, format = "text", ...) {
  format <- match.arg(format, c("text", "json", "yaml", "xml"))

  glue_sql2(con, "EXPLAIN ", if (!is.null(format)) "(FORMAT {format}) ", sql)
}
#' @export
sql_query_explain.PostgreSQL <- sql_query_explain.PqConnection

#' @export
sql_query_insert.PqConnection <- function(con,
                                          table,
                                          from,
                                          insert_cols,
                                          by,
                                          conflict = c("error", "ignore"),
                                          ...,
                                          returning_cols = NULL,
                                          method = NULL) {
  check_string(method, allow_null = TRUE)
  method <- method %||% "on_conflict"
  arg_match(method, c("on_conflict", "where_not_exists"), error_arg = "method")
  if (method == "where_not_exists") {
    return(NextMethod("sql_query_insert"))
  }

  # https://stackoverflow.com/questions/17267417/how-to-upsert-merge-insert-on-duplicate-update-in-postgresql
  # https://www.sqlite.org/lang_UPSERT.html
  conflict <- rows_check_conflict(conflict)

  parts <- rows_insert_prep(con, table, from, insert_cols, by, lvl = 0)
  by_sql <- escape(ident(by), parens = TRUE, collapse = ", ", con = con)

  clauses <- list(
    parts$insert_clause,
    sql_clause_select(con, sql("*")),
    sql_clause_from(parts$from),
    sql_clause("ON CONFLICT", by_sql),
    {if (conflict == "ignore") sql("DO NOTHING")},
    sql_returning_cols(con, returning_cols, table)
  )
  sql_format_clauses(clauses, lvl = 0, con)
}
#' @export
sql_query_insert.PostgreSQL <- sql_query_insert.PqConnection

#' @export
sql_query_upsert.PqConnection <- function(con,
                                          table,
                                          from,
                                          by,
                                          update_cols,
                                          ...,
                                          returning_cols = NULL,
                                          method = NULL) {
  check_string(method, allow_null = TRUE)
  method <- method %||% "on_conflict"
  arg_match(method, c("cte_update", "on_conflict"), error_arg = "method")

  if (method == "cte_update") {
    return(NextMethod("sql_query_upsert"))
  }

  # https://stackoverflow.com/questions/17267417/how-to-upsert-merge-insert-on-duplicate-update-in-postgresql
  # https://www.sqlite.org/lang_UPSERT.html
  parts <- rows_prep(con, table, from, by, lvl = 0)

  insert_cols <- c(by, update_cols)
  select_cols <- ident(insert_cols)
  insert_cols <- escape(ident(insert_cols), collapse = ", ", parens = TRUE, con = con)

  update_values <- set_names(
    sql_table_prefix(con, update_cols, "excluded"),
    update_cols
  )
  update_cols <- sql_escape_ident(con, update_cols)

  by_sql <- escape(ident(by), parens = TRUE, collapse = ", ", con = con)
  clauses <- list(
    sql_clause_insert(con, insert_cols, table),
    sql_clause_select(con, select_cols),
    sql_clause_from(parts$from),
    # `WHERE true` is required for SQLite
    sql("WHERE true"),
    sql_clause("ON CONFLICT ", by_sql),
    sql("DO UPDATE"),
    sql_clause_set(update_cols, update_values),
    sql_returning_cols(con, returning_cols, table)
  )
  sql_format_clauses(clauses, lvl = 0, con)
}

#' @export
sql_query_upsert.PostgreSQL <- sql_query_upsert.PqConnection

#' @export
sql_values_subquery.PqConnection <- sql_values_subquery_column_alias

#' @export
sql_values_subquery.PostgreSQL <- sql_values_subquery.PqConnection

#' @export
sql_escape_date.PostgreSQL <- function(con, x) {
  DBI::dbQuoteLiteral(con, x)
}
#' @export
sql_escape_date.PqConnection <- sql_escape_date.PostgreSQL


#' @export
supports_window_clause.PqConnection <- function(con) {
  TRUE
}

#' @export
supports_window_clause.PostgreSQL <- function(con) {
  TRUE
}

#' @export
db_supports_table_alias_with_as.PqConnection <- function(con) {
  TRUE
}

#' @export
db_supports_table_alias_with_as.PostgreSQL <- function(con) {
  TRUE
}

#' @export
db_col_types.PqConnection <- function(con, table, call) {
  table <- as_table_path(table, con, error_call = call)
  res <- DBI::dbSendQuery(con, glue_sql2(con, "SELECT * FROM {.tbl table} LIMIT 0"))
  on.exit(DBI::dbClearResult(res))
  DBI::dbFetch(res, n = 0)
  col_info_df <- DBI::dbColumnInfo(res)
  set_names(col_info_df[[".typname"]], col_info_df[["name"]])
}

#' @export
db_col_types.PostgreSQL <- db_col_types.PqConnection

utils::globalVariables(c("strpos", "%::%", "%FROM%", "%ILIKE%", "DATE", "EXTRACT", "TO_CHAR", "string_agg", "%~*%", "%~%", "MONTH", "DOY", "DATE_TRUNC", "INTERVAL", "FLOOR", "WEEK", "make_date", "date_part"))
