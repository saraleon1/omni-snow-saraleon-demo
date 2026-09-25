# Order Items Metrics

Covers `dbt_sleon_prod__order_items` and `dbt_sleon_prod__products`.

All order revenue uses `product_price` from the order items table.

## Key definitions

- **Food items**: flagged via `is_food_item` on `order_items`
- **Drink items**: flagged via `is_drink_item` on `order_items`
- Revenue should always be broken out by product category when possible

## What NOT to use

Do not use `stg_order_items` or `stg_products` for reporting — those are staging tables. Always use the production `dbt_sleon_prod` views. some change another change and another ad another!
