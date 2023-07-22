## 0.0 Libraries ----

if (!require("RPostgres")) install.packages("RPostgres"); library(RPostgres)
if (!require("RSQLite")) install.packages("RSQLite"); library(RSQLite)
if (!require("lubridate")) install.packages("lubridate"); library(lubridate)
if (!require("tidyverse")) install.packages("tidyverse"); library(tidyverse)
if (!require("dplyr")) install.packages("dplyr"); library(dplyr)
if (!require("tidyr")) install.packages("tidyr"); library(tidyr)
if (!require("xts")) install.packages("xts"); library(xts)
if (!require("data.table")) install.packages("data.table"); library(data.table)
if (!require("PerformanceAnalytics")) install.packages("PerformanceAnalytics"); library(PerformanceAnalytics)
if (!require("frenchdata")) install.packages("frenchdata"); library(frenchdata)
if (!require("ggplot2")) install.packages("ggplot2"); library(ggplot2)
if (!require("knitr")) install.packages("knitr"); library(knitr)
if (!require("stargazer")) install.packages("stargazer"); library(stargazer)

setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

## 0.1 Data Collection ----

## Data connection
# Establish a connection to the WRDS (Wharton Research Data Services) database
username <- "" # credentials need to be entered here
password <- ""  # credentials need to be entered here

start_date <- ymd("1960-01-01")
end_date <- ymd("2023-01-01")

wrds <- dbConnect(
  Postgres(),
  host = "wrds-pgdata.wharton.upenn.edu",
  dbname = "wrds",
  port = 9737,
  sslmode = "require",
  user = username, 
  password = password 
)

# Retrieve COMPUSTAT & CRSP data

# Get the linktable to be able to join Compustat and CRSP data using gvkey and permno
linktable_db <- tbl(
  wrds,
  in_schema("crsp", "ccmxpf_linktable")
)

# Filter the linktable to select valid link types and flags
# Select specific columns for the linktable and collect the data into a local dataframe
linktable <- linktable_db %>% 
  filter(linktype %in% c("LU", "LC") &
           linkprim %in% c("P", "C") &
           usedflag == 1) %>% 
  select(permno = lpermno, gvkey, linkdt, linkenddt) %>% 
  collect() %>% 
  mutate(linkenddt = replace_na(linkenddt, today()))

# Get R&D expenses data from the COMPUSTAT dataset
r_d_s <- tbl(wrds, in_schema("comp", "funda")) %>%
  select(date = datadate, gvkey,
         r_d = xrd, sales_year = revt, equity = ceq) %>% 
  as.data.table()

# Filter R&D expenses data based on a date range
r_d_sdate_filtered <- r_d_s[date > ymd("1976-01-01") & date < ymd("2023-01-01")]

# Add the year and correct it based on the statement date
r_d_sdate_filtered[, c("month", "year") := list(month(date), year(date))]
r_d_sdate_filtered[, year := ifelse(month > 4, year + 1, year)]
r_d_sdate_filtered[, month := NULL] # drop month as we don't need it


## 0.2 De-listing ----

# Set the start and end dates for CRSP Monthly data
start_date <- as.Date("1976-01-01")
end_date <- as.Date("2023-01-01")

## Returns
# Get CRSP Monthly returns data
msf_db <- tbl(wrds, in_schema("crsp", "msf"))

## Names
# Get CRSP Monthly names data
msenames_db <- tbl(wrds, in_schema("crsp", "msenames"))

## Delisting
# Get CRSP Monthly delisting data
msedelist_db <- tbl(wrds, in_schema("crsp", "msedelist"))

# Retrieve CRSP Monthly data and join with other tables
crsp_monthly <- msf_db %>% 
  filter(date >= start_date & date <= end_date) %>% 
  inner_join(msenames_db %>% 
               filter(shrcd %in% c(10, 11)) %>% 
               select(permno , exchcd, siccd, namedt, nameendt), by = c("permno")) %>% 
  filter(date >= namedt & date <= nameendt) %>% 
  mutate(month = floor_date(date, "month")) %>% 
  left_join(msedelist_db %>% 
              select(permno, dlstdt, dlret, dlstcd) %>% 
              mutate(month = floor_date(dlstdt, "month")), by = c("permno", "month")) %>% 
  select(permno, month, return = ret, retx, shares = shrout, price = altprc, exchcd, siccd, dlret, dlstcd) %>% 
  mutate(month = as.Date(month),
         market_eq = abs(price * shares)/1000) %>% 
  select(-price, -shares) %>% 
  collect()

# Assign exchange labels based on exchcd values
crsp_monthly <- crsp_monthly %>% 
  mutate(exchange = case_when(
    exchcd %in% c(1, 31) ~ "NYSE",
    exchcd %in% c(2, 32) ~ "AMEX",
    exchcd %in% c(3, 33) ~ "NASDAQ",
    .default = "Other"
  ))

# Filter CRSP Monthly data to include only specific exchanges
crsp_monthly <- crsp_monthly %>%  
  filter(
    exchcd == 1|exchcd == 2|exchcd == 3
  )

# Rename the 'month' column as 'date'
crsp_monthly <- crsp_monthly %>% 
  mutate(
    date = month
  )

# Join CRSP Monthly data with the linktable
links2 <- crsp_monthly %>% 
  inner_join(linktable, by = "permno", relationship = "many-to-many") %>% 
  filter(!is.na(gvkey) & (date >= linkdt & date <= linkenddt)) %>% 
  select(permno, gvkey, date) %>% 
  as.data.table()

# Merge CRSP Monthly data with additional linked information
crsp_enriched2 <- merge(crsp_monthly, links2, 
                        by = c("permno", "date"), all.x = T)


## 0.3 End of De-listing ----


# CRSP data to calculate market equity value
crsp_data <- tbl(wrds, in_schema("crsp", "msf")) %>% 
  filter(hexcd %in% 1:3) %>% # 1 = NYSE, 2 = AMEX = NYSE MKT, 3 = NASDAQ
  select(date, permno, return = ret, price = altprc, shares = shrout) %>% 
  mutate(market_eq = abs(price * shares)/1000) %>%
  select(-price, -shares) %>% 
  as.data.table()

# Filter CRSP data based on a date range
crsp_data_date_filtered <- crsp_data[date >= ymd("1976-01-01") & 
                                       date <= ymd("2023-01-01")]

# Make the final link table by joining CRSP data with the linktable
links <- crsp_data_date_filtered %>% 
  inner_join(linktable, by = "permno", relationship = "many-to-many") %>% 
  filter(!is.na(gvkey) & (date >= linkdt & date <= linkenddt)) %>% 
  select(permno, gvkey, date) %>% 
  as.data.table()

# Merge CRSP data and links to enrich the data
crsp_enriched <- merge(crsp_data_date_filtered, links, 
                       by = c("permno", "date"), all.x = T)

# Add the month and year columns to the enriched data
crsp_enriched[, c("month", "year") := list(month(date), year(date))]

# Prepare the data for portfolio formation by filtering for April-end data
data_for_sort <- merge(crsp_enriched[month == 4], r_d_sdate_filtered, 
                       by = c("year", "gvkey"), all.x = T) %>% 
  select(
    -c(date.x,month)
  ) %>% 
  filter(!is.na(return))


## 1.1 Sorting variable ----

## Filtering out observations with missing gvkey
data <- data_for_sort[!is.na(data_for_sort$gvkey),]

## Computing RDM (Research and Development to Market Equity ratio)
data$RDM <- data$r_d/data$market_eq

## Note for the results of this filtering. I want to take ONLY those observations
## which have a COMPLETE time-series. I define a complete time-series as one 
## which has n consecutive observations. 

## Filtering the data for a specific year (1999) to identify gvkeys with non-missing RDM values
filtro <- data %>% 
  filter(year == 1999) %>% 
  select(gvkey, RDM) %>% 
  na.omit() %>% 
  distinct(gvkey)

## Sorting the data for time-frames larger than 1999 in fiscal years.
df_sort <- data %>% 
  filter(gvkey %in% filtro$gvkey) %>% 
  filter(year >= 1999)

## Removing observations with missing RDM values
df_sort <- df_sort[c(!is.na(df_sort$RDM)), ]

## Obtaining the gvkeys for companies with a complete time-frame (n >= 22 observations)
GVKEY_chosen <- df_sort %>% 
  group_by(gvkey) %>% 
  mutate(n = length(date.y)) %>% 
  filter(n >= 22) %>%  ## condition 
  distinct(gvkey)

## Creating the final data-set with only the chosen gvkeys for further sorting
df_sort <- df_sort %>% 
  filter(gvkey %in% GVKEY_chosen$gvkey)


df_sort_summary <- as.data.frame(df_sort[,c("market_eq","sales_year","r_d","RDM")])
colnames(df_sort_summary) <- c("Market Value of Equity*","Yearly Sales*","R and D Expenditure*","R and D Sorting Variable")
stargazer(df_sort_summary, title="Summary statistics", header = FALSE, align = TRUE, 
          summary.stat=c("n","mean","median","sd"), out = "out/summary_gen.html")



## 1.2 Portfolio Sorts ----

# Checking classes of variables in df_sort
unlist(lapply(df_sort, class))

# Function to perform portfolio sorts
portfolio_sort <- function(dataframe, startdate, endate){
  
  for(i in startdate:(endate - 1) ){ # Note we sort until one year before cause no return in 2024
    
    # For naming later on
    index <- i - 1999
    varname <- paste0("psort_", index)
    
    # Filter for fiscal year of interest
    df_tmp <- filter(dataframe, year == i)
    
    # Get the portfolio sorts for the tmp fiscal year
    df_tmp <- df_tmp %>%
      mutate(!!varname := ntile(RDM, 5)) %>% 
      select(gvkey, year, all_of(varname))
    
    # Left Join df_tmp, (We will have NAs for any unmatched year)
    dataframe <- dataframe %>% left_join(df_tmp, by = c("gvkey", "year")) 
    
  }
  
  return(dataframe)
}

# Call the portfolio_sort function to sort the dataframe
df_sorted <- portfolio_sort(dataframe = df_sort, startdate = 1999, endate = 2023)


# Prepare a list to store sorted portfolios
ports <- list()
count <- 1
count2 <- 11

# Convert df_sorted to a data frame
df_sorted <- as.data.frame(df_sorted)

# Loop through columns 11 to 34 (count2 starts at 11)
for(i in 11:34){
  
  # Store non-NA values from the current column in ports list
  ports[[count]] <- df_sorted[c(!is.na(df_sorted[,count2])),count2]
  count <- count + 1
  count2 <- count2 + 1
  
}

# Unlist the ports list to create a vector
ports <- unlist(ports)

# Calculate the length of the ports vector
length(ports)

# Add the ports vector as a column to df_sorted
df_sorted <- cbind(df_sorted[,1:10], ports)

## Note that in section 0.1 We had CRSP_enriched which contains monthly returns for each stock
## Based on this we merge this info into the new df_sorted.

# Select relevant columns from crsp_enriched
crsp_merge <- crsp_enriched %>% 
  select(gvkey, year, month, date, return)

# Merge df_sorted and crsp_merge using gvkey and year as keys
df_sorted_monthly <- df_sorted %>% 
  left_join(crsp_merge, by = c("gvkey", "year")) %>% 
  select(gvkey, date.y, date, year, month, return.x, return.y, RDM, market_eq, ports)

# Rename the columns of df_sorted_monthly
colnames(df_sorted_monthly) <- c("gvkey", "date_yearly", "date_monthly", "year",
                                 "month", "return_yearly", "return_monthly",
                                 "RDM", "market_eq", "ports")


df_sorted_summary <- data.frame(p1 = apply(df_sorted[df_sorted$ports==1,
                                                             c("market_eq","sales_year","r_d","RDM")], 
                                           2, mean, na.rm = TRUE),
                          p2 = apply(df_sorted[df_sorted$ports==2,
                                                             c("market_eq","sales_year","r_d","RDM")], 
                                           2, mean, na.rm = TRUE),
                          p3 = apply(df_sorted[df_sorted$ports==3,
                                                             c("market_eq","sales_year","r_d","RDM")], 
                                           2, mean, na.rm = TRUE),
                          p4 = apply(df_sorted[df_sorted$ports==4,
                                                             c("market_eq","sales_year","r_d","RDM")], 
                                           2, mean, na.rm = TRUE),
                          p5 = apply(df_sorted[df_sorted$ports==5,
                                                             c("market_eq","sales_year","r_d","RDM")], 
                                           2, mean, na.rm = TRUE))
colnames(df_sorted_summary) <- c("1 (Low)","2","3","4","5 (High)")
rownames(df_sorted_summary) <- c("Market Value of Equity*","Yearly Sales*","R&D Expenditure*","R&D Sorting Variable")

df_sorted_summary_out <- kable(df_sorted_summary, digits=2, caption="Summary statistics grouped by the R&D Sorting Variable")
writeLines(df_sorted_summary_out, "out/summary_sorted.html")
print(df_sorted_summary_out)

df_sorted_port_summary <- data.frame(p1 = apply(df_sorted_monthly[df_sorted_monthly$ports==1,
                                                             c("return_monthly","return_yearly")], 
                                           2, mean, na.rm = TRUE),
                          p2 = apply(df_sorted_monthly[df_sorted_monthly$ports==2,
                                                             c("return_monthly","return_yearly")], 
                                           2, mean, na.rm = TRUE),
                          p3 = apply(df_sorted_monthly[df_sorted_monthly$ports==3,
                                                             c("return_monthly","return_yearly")], 
                                           2, mean, na.rm = TRUE),
                          p4 = apply(df_sorted_monthly[df_sorted_monthly$ports==4,
                                                             c("return_monthly","return_yearly")], 
                                           2, mean, na.rm = TRUE),
                          p5 = apply(df_sorted_monthly[df_sorted_monthly$ports==5,
                                                             c("return_monthly","return_yearly")], 
                                           2, mean, na.rm = TRUE))
colnames(df_sorted_port_summary) <- c("1 (Low)","2","3","4","5 (High)")
rownames(df_sorted_port_summary) <- c("Monthly Returns","Yearly Returns")

df_sorted_port_summary_out <- kable(df_sorted_port_summary, digits=2, caption="Mean returns of sorted portfolios")
writeLines(df_sorted_port_summary_out, "out/summary_sorted_ret.html")
print(df_sorted_port_summary_out)


## 1.3 Long-short return differential ----

## yearly return differentials
df_sorted_returns <- df_sorted %>%
  group_by(year, ports) %>%
  summarise(average_return = mean(return)) %>% 
  ungroup()

df_longshort <- df_sorted_returns %>%
  filter(ports %in% c(1, 5)) %>%
  spread(ports, average_return) %>%
  mutate(longshort = `5` - `1`) %>% 
  select(year, longshort)

df_longshort <- as.data.frame(df_longshort)

png(file="out/ret_diff.png",width=10, height=4, units="in", res=600, pointsize=0.5)
ggplot(df_longshort, aes(x = year, y = longshort)) +
  geom_line(color = "lightblue", size = 1) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "black") +
  labs(x = "Year", y = "Long-short return differential") +
  theme_minimal() +
  theme(plot.title = element_text(size = 12, face = "bold"),
        axis.title = element_text(size = 8),
        axis.text = element_text(size = 7),
        axis.line = element_line(size = 0.5),
        panel.grid = element_blank(),
        panel.grid.major.y = element_line(color = "gray95"),
        panel.border = element_blank(),
        text=element_text(family="serif"))
dev.off()


## monthly return differentials

# Select relevant columns from crsp_enriched
crsp_merge <- crsp_enriched %>% 
  select(gvkey, year, month, date, return)

# Merge df_sorted and crsp_merge using gvkey and year as keys
df_sorted_monthly <- df_sorted %>% 
  left_join(crsp_merge, by = c("gvkey", "year")) %>% 
  select(gvkey, date.y, date, year, month, return.x, return.y, RDM, market_eq, ports)

# Rename the columns of df_sorted_monthly
colnames(df_sorted_monthly) <- c("gvkey", "date_yearly", "date_monthly", "year",
                                 "month", "return_yearly", "return_monthly",
                                 "RDM", "market_eq", "ports")

# Filter df_sorted_monthly based on specific conditions
df_sorted_monthly <- df_sorted_monthly[c(df_sorted_monthly$ports == 1 | df_sorted_monthly$ports == 5),]

# Group df_sorted_monthly by year, month, and ports, then calculate the mean return
df_sorted_monthly <- df_sorted_monthly |> 
  group_by(year, month, ports) |> 
  mutate(return = mean(return_monthly, na.rm = TRUE)) |> 
  ungroup() |> 
  select(year, month, ports, return)

# Remove duplicate rows from df_sorted_monthly
df_sorted_monthly <- unique(df_sorted_monthly)

# Create df_longshort_monthly by filtering df_sorted_monthly for ports 1 and 5,
# spreading the values into columns, calculating the long-short differential,
# and selecting the relevant columns
df_longshort_monthly <- df_sorted_monthly %>%
  filter(ports %in% c(1, 5)) %>%
  spread(ports, return) %>%
  mutate(longshort = `5` - `1`) %>% 
  select(year, month, longshort)

# Convert df_longshort_monthly to a data frame
df_longshort_monthly <- as.data.frame(df_longshort_monthly)


# Create a character vector for month and year
months <- sprintf("%02d", df_longshort_monthly$month)
years <- as.character(df_longshort_monthly$year)

# Create a new column for the date
df_longshort_monthly$date <- as.Date(paste0("01-", months, "-", years), format = "%d-%m-%Y")

png(file="out/ret_diff_monthly.png",width=10, height=4, units="in", res=600, pointsize=0.5)
ggplot(df_longshort_monthly, aes(x = date, y = longshort)) +
  geom_line(color = "lightblue", size = 1) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "black") +
  labs(x = "Date", y = "Long-short return differential") +
  theme_minimal() +
  theme(plot.title = element_text(size = 12, face = "bold"),
        axis.title = element_text(size = 8),
        axis.text = element_text(size = 7),
        axis.line = element_line(size = 0.5),
        panel.grid = element_blank(),
        panel.grid.major.y = element_line(color = "gray95"),
        panel.border = element_blank(),
        text=element_text(family="serif"))
dev.off()

## cumulative return differential calculation
cumulative_longshort_monthly <- c()

for (i in 1:288) {
  
  cumulative_longshort_monthly[i] <- prod(1+df_longshort_monthly$longshort[1:i]) -1
  
}

cumulative_longshort_monthly <- data.frame(date = df_longshort_monthly$date, Cum_ret_diff = cumulative_longshort_monthly)

# Specify the dates for the vertical lines
vertical_dates_h <- c("2000-02-01", "2007-12-01", "2010-01-01", "2020-01-01")  
vertical_dates_l <- c("2002-09-01", "2008-12-01","2013-04-01", "2020-02-01")

# Compound Annual Growth Rate (CAGR)
CAGR <- (df_longshort[24,2]/df_longshort[1,2])^(1/23) - 1


# plot of the cumulative return differentials, with highlights for specific dates
png(file="out/cumm_ret_diff_monthly.png",width=10, height=4, units="in", res=600, pointsize=0.5)
ggplot(cumulative_longshort_monthly) +
  geom_rect(aes(xmin = as.Date(vertical_dates_h[1]), xmax = (as.Date(vertical_dates_l[1])), ymin = -Inf, ymax = Inf),
            fill = "gray90", alpha = 0.1) +
  geom_rect(aes(xmin = as.Date(vertical_dates_h[2]), xmax = (as.Date(vertical_dates_l[2])), ymin = -Inf, ymax = Inf),
            fill = "gray90", alpha = 0.1) +
  geom_rect(aes(xmin = as.Date(vertical_dates_h[3]), xmax = (as.Date(vertical_dates_l[3])), ymin = -Inf, ymax = Inf),
            fill = "gray90", alpha = 0.1) +
  geom_rect(aes(xmin = as.Date(vertical_dates_h[4]), xmax = (as.Date(vertical_dates_l[4])), ymin = -Inf, ymax = Inf),
            fill = "gray90", alpha = 0.1) +
  geom_line(aes(x = date, y = Cum_ret_diff), color = "lightblue", size = 1) +
  labs(x = "Date", y = "Cumulative return differential") +
  theme_minimal() +
  theme(plot.title = element_text(size = 12, face = "bold"),
        axis.title = element_text(size = 8),
        axis.text = element_text(size = 7),
        axis.line = element_line(size = 0.5),
        panel.grid = element_blank(),
        panel.grid.major.y = element_line(color = "gray95"),
        panel.border = element_blank(),
        text=element_text(family="serif"))
dev.off()

## 2.3 Assess the return differential’s risk exposures---- 

## loading data from ff and q5 factor models
#FF5 <- read.csv("data/F-F_Research_Data_5_Factors_2x3.csv")

## preparation of the data for regressions

FF5 <- download_french_data("Fama/French 5 Factors (2x3)")
FF5 <- FF5$subsets$data[[1]]

FF5 <- FF5[c(FF5$date >= 199901 & FF5$date <= 202212), ]

colnames(FF5)[2] <- "Mkt.RF"

df_longshort_monthly <- cbind(df_longshort_monthly, FF5[,2:7])
df_longshort_monthly[,5:10] <- df_longshort_monthly[,5:10]/100

## Regressions with excess return differential
reg.CAPM <- lm((longshort - RF) ~ Mkt.RF, data = df_longshort_monthly)
reg.FF <- lm((longshort - RF) ~ Mkt.RF + SMB + HML, data = df_longshort_monthly)


stargazer(reg.CAPM, header=FALSE, no.space=TRUE, dep.var.caption="", single.row = TRUE, 
          title="Regression Results for CAPM", out = "out/port_sort_CAPM.html")

stargazer(reg.FF, header=FALSE, no.space=TRUE, dep.var.caption="", single.row = TRUE, 
          title="Regression Results for Fama-French 3-Factor Model", out = "out/port_sort_FF3.html")


# Define the significance levels
p_99 <- 0.99  # 99% confidence level
p_95 <- 0.95  # 95% confidence level

# Calculate VaR at 99% and 95%
var_99_longshort <- VaR(df_longshort_monthly$longshort, p = p_99, method = "historical")
var_95_longshort <- VaR(df_longshort_monthly$longshort, p = p_95, method = "historical")

var_99_value <- VaR(df_longshort_monthly$HML, p = p_99, method = "historical")
var_95_value <- VaR(df_longshort_monthly$HML, p = p_95, method = "historical")

var_99_size <- VaR(df_longshort_monthly$SMB, p = p_99, method = "historical")
var_95_size <- VaR(df_longshort_monthly$SMB, p = p_95, method = "historical")

# Calculate ES at 99% and 95%
es_99_longshort <- ES(df_longshort_monthly$longshort, p = p_99, method = "historical")
es_95_longshort <- ES(df_longshort_monthly$longshort, p = p_95, method = "historical")

es_99_value <- ES(df_longshort_monthly$HML, p = p_99, method = "historical")
es_95_value <- ES(df_longshort_monthly$HML, p = p_95, method = "historical")

es_99_size <- ES(df_longshort_monthly$SMB, p = p_99, method = "historical")
es_95_size <- ES(df_longshort_monthly$SMB, p = p_95, method = "historical")



# Print the results
VaR.measure <- matrix(c(var_95_longshort,var_99_longshort,var_95_value,var_99_size,var_95_size,var_99_size), 
                        ncol=2, nrow=3,byrow=T, dimnames=list(c("Return differential","SMB","HML"), c("95%","99%")))
ES.measure <- matrix(c(es_95_longshort,es_99_longshort,es_95_value,es_99_size,es_95_size,es_99_size), 
                        ncol=2,nrow=3,  byrow=T, dimnames=list(c("Return differential","SMB","HML"), c("95%","99%")))

# Custom formatting function
format_percentage <- function(x) {
  paste0(formatC(x * 100, format = "f", digits = 2), "%")
}

# Apply the formatting function to the matrix
VaR.measure <- apply(VaR.measure, 1:2, format_percentage)
ES.measure <- apply(ES.measure, 1:2, format_percentage)


VaR.measure.out <- kable(VaR.measure, caption="Value at Risk", suffix = "%")
writeLines(VaR.measure.out, "out/VaR_measure_out.html")
print(VaR.measure.out)


ES.measure.out <- kable(ES.measure, caption="Expected Shortfall")
writeLines(ES.measure.out, "out/ES_measure_out.html")
print(ES.measure.out)