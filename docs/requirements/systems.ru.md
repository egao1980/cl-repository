# Системные требования/границы модулей (RU)

Исходный документ: `docs/requirements/systems.md`

## Подсистемы

- `cl-oci`: модель OCI (дескрипторы, manifests, index, config, serialization).
- `cl-oci-client`: HTTP-клиент OCI Distribution Spec.
- `cl-repository-packager`: упаковка CL-систем в OCI.
- `cl-repository-client`: установка/резолв/CLI.
- `cl-repository-ql-exporter`: экспорт Quicklisp/Ultralisp в OCI.

## Принцип

Подсистемы должны быть слабо связаны и переиспользуемы:
- transport отдельно от формата,
- packaging отдельно от install/runtime,
- exporter как bootstrap-механизм для экосистемы.

Для точных интерфейсов и требований по каждому модулю см. английскую версию.
