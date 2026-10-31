# Data Catalog for Gold Layer

## Overview
The Gold Layer is the business-level data representation, structured to support analytical and reporting use cases. It consists of **dimension tables** and **fact tables** for specific business metrics.

All Gold objects are **tables**, loaded by the stored procedure `gold.load_gold` (`scripts/gold/proc_load_gold.sql`). Dimensions are never truncated, so surrogate keys stay stable and product history is kept.

Every table also has technical columns: `dwh_insert_date` (when the row was first loaded) and, on dimensions, `dwh_update_date` (when the row was last changed).

---

### 1. **gold.dim_customers**
- **Purpose:** Stores customer details enriched with demographic and geographic data. **SCD Type 1**: when a customer's details change, the row is overwritten (no history).
- **Columns:**

| Column Name      | Data Type     | Description                                                                                   |
|------------------|---------------|-----------------------------------------------------------------------------------------------|
| customer_key     | INT           | Surrogate key uniquely identifying each customer record in the dimension table.               |
| customer_id      | INT           | Unique numerical identifier assigned to each customer.                                        |
| customer_number  | NVARCHAR(50)  | Alphanumeric identifier representing the customer, used for tracking and referencing.         |
| first_name       | NVARCHAR(50)  | The customer's first name, as recorded in the system.                                         |
| last_name        | NVARCHAR(50)  | The customer's last name or family name.                                                     |
| country          | NVARCHAR(50)  | The country of residence for the customer (e.g., 'Australia').                               |
| marital_status   | NVARCHAR(50)  | The marital status of the customer (e.g., 'Married', 'Single').                              |
| gender           | NVARCHAR(50)  | The gender of the customer (e.g., 'Male', 'Female', 'n/a').                                  |
| birthdate        | DATE          | The date of birth of the customer, formatted as YYYY-MM-DD (e.g., 1971-10-06).               |
| create_date      | DATE          | The date and time when the customer record was created in the system|

---

### 2. **gold.dim_products**
- **Purpose:** Provides information about the products and their attributes. Built as a **Slowly Changing Dimension Type 2**: one row per product version, so cost and attribute history is kept and each sale links to the version that was valid on its order date. On every load, `gold.load_gold` compares each product's current row in Silver with its current version in Gold; if the name, category, maintenance, cost or product line changed, the old version is closed (`valid_to` = day before the load) and a new version is opened (`valid_from` = load date).
- **Columns:**

| Column Name     | Data Type     | Description                                                                                   |
|-----------------|---------------|-----------------------------------------------------------------------------------------------|
| product_key     | INT           | Surrogate key uniquely identifying each product **version** in the dimension table.           |
| product_id      | INT           | A unique identifier assigned to the product version in the source system.                     |
| product_number  | NVARCHAR(50)  | Business key of the product; the same for all versions (e.g., 'FR-R92B-58').                  |
| product_name    | NVARCHAR(50)  | Descriptive name of the product, including details such as type, color, and size.             |
| category_id     | NVARCHAR(50)  | A unique identifier for the product's category, linking to its high-level classification.     |
| category        | NVARCHAR(50)  | The broader classification of the product (e.g., Bikes, Components).                          |
| subcategory     | NVARCHAR(50)  | A more detailed classification of the product within the category, such as product type.      |
| maintenance     | NVARCHAR(50)  | Indicates whether the product requires maintenance (e.g., 'Yes', 'No').                       |
| cost            | INT           | The cost of the product during this version's validity period.                                |
| product_line    | NVARCHAR(50)  | The product line or series (e.g., Road, Mountain).                                            |
| start_date      | DATE          | Start date of this version, as delivered by the source system.                                |
| valid_from      | DATE          | Start of the period this version applies to (first version starts at 1900-01-01).             |
| valid_to        | DATE          | End of the period this version applies to (current version ends at 9999-12-31).               |
| is_current      | INT           | 1 = current version of the product, 0 = historical version.                                  |
| version_number  | INT           | Sequence of the version per product (1 = first version).                                      |

---------------------|---------------|-----------------------------------------------------------------------------------------------|
| product_key         | INT           | Surrogate key uniquely identifying each product record in the product dimension table.         |
| product_id          | INT           | A unique identifier assigned to the product for internal tracking and referencing.            |
| product_number      | NVARCHAR(50)  | A structured alphanumeric code representing the product, often used for categorization or inventory. |
| product_name        | NVARCHAR(50)  | Descriptive name of the product, including key details such as type, color, and size.         |
| category_id         | NVARCHAR(50)  | A unique identifier for the product's category, linking to its high-level classification.     |
| category            | NVARCHAR(50)  | The broader classification of the product (e.g., Bikes, Components) to group related items.  |
| subcategory         | NVARCHAR(50)  | A more detailed classification of the product within the category, such as product type.      |
| maintenance_required| NVARCHAR(50)  | Indicates whether the product requires maintenance (e.g., 'Yes', 'No').                       |
| cost                | INT           | The cost or base price of the product, measured in monetary units.                            |
| product_line        | NVARCHAR(50)  | The specific product line or series to which the product belongs (e.g., Road, Mountain).      |
| start_date          | DATE          | The date when the product became available for sale or use, stored in|

---

### 3. **gold.fact_sales**
- **Purpose:** Stores transactional sales data for analytical purposes.
- **Columns:**

| Column Name     | Data Type     | Description                                                                                   |
|-----------------|---------------|-----------------------------------------------------------------------------------------------|
| order_number    | NVARCHAR(50)  | A unique alphanumeric identifier for each sales order (e.g., 'SO54496').                      |
| product_key     | INT           | Surrogate key linking the order to the product dimension table.                               |
| customer_key    | INT           | Surrogate key linking the order to the customer dimension table.                              |
| order_date      | DATE          | The date when the order was placed.                                                           |
| shipping_date   | DATE          | The date when the order was shipped to the customer.                                          |
| due_date        | DATE          | The date when the order payment was due.                                                      |
| sales_amount    | INT           | The total monetary value of the sale for the line item, in whole currency units (e.g., 25).   |
| quantity        | INT           | The number of units of the product ordered for the line item (e.g., 1).                       |
| price           | INT           | The price per unit of the product for the line item, in whole currency units (e.g., 25).      |

---

### 4. **gold.dim_date**
- **Purpose:** Calendar dimension with one row per day, used to analyze sales by day, week, month, quarter and year.
- **Columns:**

| Column Name        | Data Type    | Description                                                                         |
|--------------------|--------------|-------------------------------------------------------------------------------------|
| date_key           | INT          | Key in YYYYMMDD format (e.g., 20130715). -1 is the 'Unknown' row for missing dates. |
| full_date          | DATE         | The calendar date.                                                                  |
| day_of_month       | INT          | Day number within the month (1–31).                                                 |
| day_of_year        | INT          | Day number within the year (1–366).                                                 |
| day_of_week        | INT          | Day number within the week, 1 = Monday to 7 = Sunday.                               |
| day_name           | NVARCHAR(30) | Full weekday name (e.g., 'Monday').                                                 |
| day_name_short     | NVARCHAR(3)  | Short weekday name (e.g., 'Mon').                                                   |
| day_type           | VARCHAR(7)   | 'Weekday' or 'Weekend'.                                                             |
| week_of_year       | INT          | ISO week number (1–53).                                                             |
| month_number       | INT          | Month number (1–12).                                                                |
| month_name         | NVARCHAR(30) | Full month name (e.g., 'July').                                                     |
| month_name_short   | NVARCHAR(3)  | Short month name (e.g., 'Jul').                                                     |
| quarter_number     | INT          | Quarter number (1–4).                                                               |
| quarter_name       | VARCHAR(2)   | Quarter label (e.g., 'Q3').                                                         |
| year               | INT          | Calendar year (e.g., 2013).                                                         |
| year_month         | CHAR(7)      | Year and month as 'YYYY-MM' (e.g., '2013-07'); sorts chronologically.               |
| first_day_of_month | DATE         | First day of the date's month.                                                      |
| last_day_of_month  | DATE         | Last day of the date's month.                                                       |
