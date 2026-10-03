"""정적 데이터 적재 (A7) — db/init 의 스키마·시드 SQL 을 DB 에 적용하는 일회성 작업

DB 컨테이너는 볼륨이 비어 있을 때만 db/init 을 실행한다. loader 는 그 밖의 경우를 맡는다.
  - 이미 데이터가 쌓인 DB (로컬, 배포 VM) 에 바뀐 시드를 반영 — 관측값·사용자 데이터는 건드리지 않음
  - initdb 없이 만든 빈 DB (관리형 DB 등) 에 스키마부터 전부 적재
시드 파일은 여러 번 적용해도 같은 결과가 되도록 작성한다 (upsert, 또는 참조 없는 테이블은 TRUNCATE 후 삽입).
"""
from .core import REQUIRED, apply, counts, find_seed_dir, migration_files, split_files

__all__ = ["REQUIRED", "apply", "counts", "find_seed_dir", "migration_files", "split_files"]
