//go:build bench

package main

import (
	"database/sql"
	"fmt"
	"time"

	_ "github.com/ncruces/go-sqlite3/driver" // wazero + SQLite-wasm; driver "sqlite3"
	_ "github.com/ncruces/go-sqlite3/embed"  // embeds the sqlite .wasm
	_ "modernc.org/sqlite"                   // native pure-Go; driver "sqlite"
)

const N = 50000

func bench(label, driver, dsn string) {
	t0 := time.Now()
	db, err := sql.Open(driver, dsn)
	must(err)
	defer db.Close()
	// First real use triggers wazero's module compile for the wasm driver.
	_, err = db.Exec("create table t (id integer primary key, name text, score real)")
	must(err)
	tStart := time.Since(t0)

	t1 := time.Now()
	tx, _ := db.Begin()
	stmt, err := tx.Prepare("insert into t (name, score) values (?, ?)")
	must(err)
	for i := 0; i < N; i++ {
		_, err = stmt.Exec(fmt.Sprintf("user%d", i), float64(i)*1.5)
		must(err)
	}
	stmt.Close()
	must(tx.Commit())
	tWrite := time.Since(t1)

	t2 := time.Now()
	rows, err := db.Query("select id, name, score from t")
	must(err)
	n := 0
	for rows.Next() {
		var id int
		var name string
		var score float64
		must(rows.Scan(&id, &name, &score))
		n++
	}
	rows.Close()
	tRead := time.Since(t2)

	fmt.Printf("%-12s startup=%-12v  insert %d=%-12v  scan %d=%-12v\n",
		label, tStart.Round(time.Microsecond), N, tWrite.Round(time.Microsecond), n, tRead.Round(time.Microsecond))
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func main() {
	fmt.Println("=== wasm (ncruces/wazero) vs native (modernc), :memory:, CGO_ENABLED=0 ===")
	bench("modernc", "sqlite", ":memory:")    // native pure-Go baseline
	bench("ncruces#1", "sqlite3", ":memory:") // wasm: first open pays the compile
	bench("ncruces#2", "sqlite3", ":memory:") // wasm: module already compiled in-process
}
