unique_db_table_name <- local({
  i <- 0

  function(table_name) {
    i <<- i + 1
    glue("{table_name}_", systime_convenient(), "_", as.character(i))
  }
})

systime_convenient <- function() {
  if (Sys.getenv("IN_PKGDOWN") != "") {
    "2020_08_28_07_13_03"
  } else {
    time <- as.character(Sys.time())
    gsub("[-: ]", "_", time)
  }
}

# Internal copy helper functions
build_copy_data <- function(dm, dest, table_names) {
  source <-
    dm %>%
    dm_apply_filters() %>%
    dm_get_tables_impl()

  copy_data_base <-
    tibble(source_name = src_tbls(dm), name = table_names) %>%
    mutate(df = map(source_name, function(x) tbl(dm, x)))

  if (is_db(dest)) {
    dest_con <- con_from_src_or_con(dest)

    pks <-
      dm_get_all_pks_impl(dm) %>%
      transmute(source_name = table, column = pk_col, pk = TRUE)

    fks <-
      dm_get_all_fks_impl(dm) %>%
      transmute(source_name = child_table, column = child_fk_cols, fk = TRUE)

    # Need to supply NOT NULL modifiers for primary keys
    # because they are difficult to add to MSSQL after the fact
    copy_data_types <-
      copy_data_base %>%
      select(source_name, df) %>%
      mutate(column = map(df, colnames)) %>%
      mutate(type = map(df, ~ map_chr(., ~ DBI::dbDataType(dest_con, .)))) %>%
      select(-df) %>%
      unnest(c(column, type)) %>%
      left_join(pks, by = c("source_name", "column")) %>%
      mutate(full_type = paste0(type, if_else(pk, " NOT NULL PRIMARY KEY", "", ""))) %>%
      group_by(source_name) %>%
      summarize(types = list(deframe(tibble(column, full_type))))

    copy_data_unique_indexes <-
      pks %>%
      transmute(source_name, unique_indexes = map(as.list(column), list))

    copy_data_indexes <-
      fks %>%
      select(source_name, column) %>%
      group_by(source_name) %>%
      summarize(indexes = map(list(column), as.list))

    copy_data <-
      copy_data_base %>%
      inner_join(copy_data_types, by = "source_name") %>%
      left_join(copy_data_unique_indexes, by = "source_name") %>%
      left_join(copy_data_indexes, by = "source_name") %>%
      mutate(indexes = map2(indexes, unique_indexes, setdiff))
  } else {
    copy_data <-
      copy_data_base
  }

  copy_data
}

# Not exported, to give us flexibility to change easily
copy_list_of_tables_to <- function(dest, copy_data,
                                   ..., overwrite = FALSE, df = NULL, name = NULL, types = NULL) {
  pmap(copy_data, copy_to, dest = dest, overwrite = overwrite, ...)
}

create_queries <- function(dest, fk_information) {
  if (is_null(fk_information)) {
    character()
  } else {
    queries_set_fk_relations(dest, fk_information)
  }
}

queries_set_fk_relations <- function(dest, fk_information) {
  db_child_tables <- fk_information$db_child_table
  child_fk_cols <- fk_information$child_fk_cols
  db_parent_tables <- fk_information$db_parent_table
  parent_pk_col <- fk_information$pk_col

  if (is_mssql(dest) || is_postgres(dest)) {
    pmap_chr(
      list(
        db_child_tables,
        child_fk_cols,
        db_parent_tables,
        parent_pk_col
      ),
      ~ glue_sql("ALTER TABLE {`DBI::SQL(..1)`} ADD FOREIGN KEY ({`..2`*}) REFERENCES {`DBI::SQL(..3)`} ({`..4`*}) ON DELETE CASCADE ON UPDATE CASCADE", .con = dest)
    )
  } else {
    return(character())
  }
}

class_to_db_class <- function(dest, class_vector) {
  if (is_mssql(dest) || is_postgres(dest)) {
    case_when(
      class_vector == "character" ~ "VARCHAR(100)",
      class_vector == "integer" ~ "INT",
      TRUE ~ class_vector
    )
  } else {
    return(class_vector)
  }
}

is_db <- function(x) {
  inherits(x, "src_sql")
}

is_src_db <- function(dm) {
  is_db(dm_get_src(dm))
}

is_mssql <- function(dest) {
  inherits(dest, "Microsoft SQL Server") ||
    inherits(dest, "src_Microsoft SQL Server")
}

is_postgres <- function(dest) {
  inherits(dest, "src_PostgreSQLConnection") ||
    inherits(dest, "src_PqConnection") ||
    inherits(dest, "PostgreSQLConnection") ||
    inherits(dest, "PqConnection")
}

src_from_src_or_con <- function(dest) {
  if (is.src(dest)) dest else dbplyr::src_dbi(dest)
}

con_from_src_or_con <- function(dest) {
  if (is.src(dest)) dest$con else dest
}

repair_table_names_for_db <- function(table_names, temporary, con) {
  if (temporary) {
    # FIXME: Better logic for temporary table names
    if (is_mssql(con)) {
      names <- paste0("#", table_names)
    } else {
      names <- table_names
    }
    names <- unique_db_table_name(names)
  } else {
    names <- table_names
  }
  names <- set_names(names, table_names)
  quote_ids(names, con)
}
