# Product Demo Infrastructure

This opt-in add-on imports the Ansible Product Demos Infrastructure setup
template into AAP:

```bash
aap-demo enable product-demo-infrastructure
```

It does not launch the template. Review its upstream cloud, broker, credential,
and managed-host requirements before launching it. The imported content is
pinned to the tested APD revision by default; set `PRODUCT_DEMOS_REF` only when
intentionally testing another revision.

See the [add-ons guide](../../docs/guides/addons.md#product-demos).
