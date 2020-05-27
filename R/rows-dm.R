#' Modifying rows for multiple tables
#'
#' @description
#' \lifecycle{experimental}
#'
#' These functions provide a framework for updating data in existing tables.
#' Unlike [compute()], [copy_to()] or [copy_dm_to()], no new tables are created
#' on the database.
#' All operations expect that both existing and new data are presented
#' in two compatible [dm] objects on the same data source.
#'
#' The functions make sure that the tables in the target dm
#' are processed in topological order so that parent (dimension)
#' tables receive insertions before child (fact) tables.
#'
#' These operations, in contrast to all other operations,
#' may lead to irreversible changes to the underlying database.
#' Therefore, in-place operation must be requested explicitly with `in_place = TRUE`.
#' By default, an informative message is given.
#'
#' @inheritParams rows_insert
#' @param x Target `dm` object.
#' @param y `dm` object with new data.
#' @param ... Must be empty.
#'
#' @return A dm object of the same [dm_ptype()] as `x`.
#'   If `in_place = TRUE`, [invisible] and identical to `x`.
#'
#' @name rows-dm
#' @example example/rows-dm.R
NULL


#' dm_rows_insert
#'
#' `dm_rows_insert()` adds new records via [rows_insert()].
#' The primary keys must differ from existing records.
#' This must be ensured by the caller and might be checked by the underlying database.
#' Use `in_place = FALSE` and apply [dm_examine_constraints()] to check beforehand.
#' @rdname rows-dm
#' @export
dm_rows_insert <- function(x, y, ..., in_place = NULL) {
  check_dots_empty()

  dm_rows(x, y, rows_insert, top_down = TRUE, in_place)
}

#' dm_rows_update
#'
#' `dm_rows_update()` updates existing records via [rows_update()].
#' Primary keys must match for all records to be updated.
#'
#' @rdname rows-dm
#' @export
dm_rows_update <- function(x, y, ..., in_place = NULL) {
  check_dots_empty()

  dm_rows(x, y, rows_update, top_down = TRUE, in_place)
}

#' dm_rows_patch
#'
#' `dm_rows_patch()` updates missing values in existing records
#' via [rows_patch()].
#' Primary keys must match for all records to be patched.
#'
#' @rdname rows-dm
#' @export
dm_rows_patch <- function(x, y, ..., in_place = NULL) {
  check_dots_empty()

  dm_rows(x, y, rows_patch, top_down = TRUE, in_place)
}

#' dm_rows_upsert
#'
#' `dm_rows_upsert()` updates existing records and adds new records,
#' based on the primary key, via [rows_upsert()].
#'
#' @rdname rows-dm
#' @export
dm_rows_upsert <- function(x, y, ..., in_place = NULL) {
  check_dots_empty()

  dm_rows(x, y, rows_upsert, top_down = TRUE, in_place)
}

#' dm_rows_delete
#'
#' `dm_rows_delete()` removes matching records via [rows_delete()],
#' based on the primary key.
#' The order in which the tables are processed is reversed.
#'
#' @rdname rows-dm
#' @export
dm_rows_delete <- function(x, y, ..., in_place = NULL) {
  check_dots_empty()

  dm_rows(x, y, rows_delete, top_down = FALSE, in_place)
}

#' dm_rows_truncate
#'
#' `dm_rows_truncate()` removes all records via [rows_truncate()],
#' only for tables in `dm`.
#' The order in which the tables are processed is reversed.
#'
#' @rdname rows-dm
#' @export
dm_rows_truncate <- function(x, y, ..., in_place = NULL) {
  check_dots_empty()

  dm_rows(x, y, rows_truncate, top_down = FALSE, in_place)
}

dm_rows <- function(x, y, operation, top_down, in_place = NULL) {
  dm_rows_check(x, y)

  if (is_null(in_place)) {
    message("Not persisting, use `in_place = FALSE` to turn off this message.")
    in_place <- FALSE
  }

  dm_rows_run(x, y, operation, top_down, in_place)
}

dm_rows_check <- function(x, y) {
  check_not_zoomed(x)
  check_not_zoomed(y)

  check_same_src(x, y)
  check_tables_superset(x, y)
  tables <- dm_get_tables_impl(y)
  walk2(dm_get_tables_impl(x)[names(tables)], tables, check_columns_superset)
  check_keys_compatible(x, y)
}

check_same_src <- function(x, y) {
  tables <- c(dm_get_tables_impl(x), dm_get_tables_impl(y))
  if (!all_same_source(tables)) {
    abort_not_same_src()
  }
}

check_tables_superset <- function(x, y) {
  tables_missing <- setdiff(src_tbls_impl(y), src_tbls_impl(x))
  if (has_length(tables_missing)) {
    abort_tables_missing(tables_missing)
  }
}

check_columns_superset <- function(target_tbl, tbl) {
  columns_missing <- setdiff(colnames(tbl), colnames(target_tbl))
  if (has_length(columns_missing)) {
    abort_columns_missing(columns_missing)
  }
}

check_keys_compatible <- function(x, y) {
  # FIXME
}



dm_rows_run <- function(x, y, rows_op, top_down, in_place) {
  # topologically sort tables
  graph <- create_graph_from_dm(x, directed = TRUE)
  topo <- igraph::topo_sort(graph, mode = if (top_down) "in" else "out")
  tables <- intersect(names(topo), src_tbls(y))

  # extract keys
  target_tbls <- dm_get_tables_impl(x)[tables]
  tbls <- dm_get_tables_impl(y)[tables]

  # FIXME: Extract keys for upsert and delete
  # Use keyholder?

  # run operation(target_tbl, source_tbl, in_place = in_place) for each table
  op_results <- map2(target_tbls, tbls, rows_op, in_place = in_place)

  if (identical(unname(op_results), unname(target_tbls))) {
    out <- x
  } else {
    out <-
      x %>%
      dm_patch_tbl(!!!op_results)
  }

  if (in_place) {
    invisible(out)
  } else {
    out
  }
}

dm_patch_tbl <- function(dm, ...) {
  check_not_zoomed(dm)

  new_tables <- list2(...)

  # FIXME: Better error message for unknown tables

  def <- dm_get_def(dm)
  idx <- match(names(new_tables), def$table)
  def[idx, "data"] <- list(unname(new_tables))
  new_dm3(def)
}


# Errors ------------------------------------------------------------------

abort_columns_missing <- function(...) {
  # FIXME
  abort("")
}

error_txt_columns_missing <- function(...) {
  # FIXME
}

abort_tables_missing <- function(...) {
  # FIXME
  abort("")
}

error_txt_tables_missing <- function(...) {
  # FIXME
}