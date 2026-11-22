# Product Demo EDA

The Product Demos EDA scenario is intentionally guarded. It needs the EDA
service plus external event-source prerequisites that aap-demo does not invent
or create.

```bash
PRODUCT_DEMOS_ENABLE_EDA=true aap-demo enable product-demo-eda
```

The command imports its Infrastructure dependency but does not create Kafka,
cloud resources, credentials, event sources, or rulebook activations. The APD
revision is pinned by default; use `PRODUCT_DEMOS_REF` only to deliberately
override it.

See the [add-ons guide](../../docs/guides/addons.md#product-demos) before opting
in.
