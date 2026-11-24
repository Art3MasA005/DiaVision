"""Existence-checked migration operations.

Why this exists: revision 0001 builds the schema from the LIVE model metadata
(`Base.metadata.create_all`). On a database that was created early and then
upgraded step by step, that was fine. On a fresh database it creates every
table the models know today, so revision 0002 then fails with "relation
consents already exists", and nobody can install from scratch.

Each later migration wraps `op` in `Guarded`, which skips an operation whose
result is already there (and a drop whose target is already gone). On an
existing database every step still runs exactly as before. On a fresh one the
steps that 0001 already covered become no-ops, and the steps it could not
cover (data moves, seeds, constraints the models do not declare) still run.
"""

from __future__ import annotations

from typing import Any

import sqlalchemy as sa


class Guarded:
    def __init__(self, op: Any) -> None:
        self._op = op

    def _insp(self) -> sa.Inspector:
        # Re-inspected each time: earlier steps in the same migration change
        # what exists.
        return sa.inspect(self._op.get_bind())

    def has_table(self, table: str) -> bool:
        return self._insp().has_table(table)

    def columns(self, table: str) -> set[str]:
        return {c["name"] for c in self._insp().get_columns(table)}

    def _indexes(self, table: str) -> set[str]:
        return {i["name"] for i in self._insp().get_indexes(table)}

    def _checks(self, table: str) -> set[str]:
        return {c["name"] for c in self._insp().get_check_constraints(table)}

    def create_table(self, name: str, *columns: Any, **kw: Any) -> None:
        if not self.has_table(name):
            self._op.create_table(name, *columns, **kw)

    def create_index(self, name: str, table: str, columns: list[str], **kw: Any) -> None:
        if name in self._indexes(table):
            return
        # create_all names single-column indexes ix_<table>_<column>; a
        # migration may have used a different name for the same index.
        existing = {tuple(i["column_names"]) for i in self._insp().get_indexes(table)}
        if tuple(columns) in existing:
            return
        self._op.create_index(name, table, columns, **kw)

    def add_column(self, table: str, column: sa.Column, **kw: Any) -> None:
        if column.name not in self.columns(table):
            self._op.add_column(table, column, **kw)

    def drop_column(self, table: str, column: str, **kw: Any) -> None:
        if column in self.columns(table):
            self._op.drop_column(table, column, **kw)

    def create_check_constraint(self, name: str, table: str, condition: str, **kw: Any) -> None:
        if name not in self._checks(table):
            self._op.create_check_constraint(name, table, condition, **kw)

    def __getattr__(self, attr: str) -> Any:
        # execute, get_bind, and anything not guarded above.
        return getattr(self._op, attr)
