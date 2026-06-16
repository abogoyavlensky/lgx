//go:build mo

package main

import (
	"database/sql"

	_ "modernc.org/sqlite"
)

func main() {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		panic(err)
	}
	defer db.Close()
	if _, err := db.Exec("create table t(x int)"); err != nil {
		panic(err)
	}
}
