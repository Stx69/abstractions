{{ config(
    alias = 'events',
    partition_by = ['block_date'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['block_date', 'unique_trade_id'],
    post_hook='{{ expose_spells(\'["ethereum"]\',
                                "project",
                                "blur",
                                \'["hildobby"]\') }}')
}}

SELECT 'ethereum' AS blockchain
, 'blur' AS project
, 'v1' AS version
, date_trunc('day', bm.evt_block_time) AS block_date
, bm.evt_block_time AS block_time
, bm.evt_block_number AS block_number
, get_json_object(bm.buy, '$.tokenId') AS token_id
, CASE WHEN erct.evt_block_time IS NOT NULL THEN 'erc721'
    ELSE 'erc1155'
    END AS token_standard
, nft.name AS collection
, CASE WHEN get_json_object(bm.buy, '$.amount')=1 THEN 'Single Item Trade'
    ELSE 'Bundle Trade'
    END AS trade_type
, get_json_object(bm.buy, '$.amount') AS number_of_items
, 'Trade' AS evt_type
, COALESCE(taker_fix.from, get_json_object(bm.sell, '$.trader')) AS seller
, COALESCE(maker_fix.to, get_json_object(bm.buy, '$.trader')) AS buyer
, CASE WHEN et.from=maker_fix.to OR et.from=get_json_object(bm.buy, '$.trader') THEN 'Buy'
    ELSE 'Offer Accepted'
    END AS trade_category
, get_json_object(bm.buy, '$.price') AS amount_raw
, CASE WHEN get_json_object(bm.buy, '$.paymentToken')='0x0000000000000000000000000000000000000000' THEN get_json_object(bm.buy, '$.price')/POWER(10, 18)
    ELSE get_json_object(bm.buy, '$.price')/POWER(10, pu.decimals)
    END AS amount_original
, CASE WHEN get_json_object(bm.buy, '$.paymentToken')='0x0000000000000000000000000000000000000000' THEN pu.price*get_json_object(bm.buy, '$.price')/POWER(10, 18)
    ELSE pu.price*get_json_object(bm.buy, '$.price')/POWER(10, pu.decimals)
    END AS amount_usd
, CASE WHEN get_json_object(bm.buy, '$.paymentToken')='0x0000000000000000000000000000000000000000' THEN 'ETH'
    ELSE pu.symbol
    END AS currency_symbol
, CASE WHEN get_json_object(bm.buy, '$.paymentToken')='0x0000000000000000000000000000000000000000' THEN '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2'
    ELSE get_json_object(bm.buy, '$.paymentToken')
    END AS currency_contract
, bm.contract_address AS project_contract_address
, get_json_object(bm.buy, '$.collection') AS nft_contract_address
, agg.name AS aggregator_name
, agg.contract_address AS aggregator_address
, bm.evt_tx_hash AS tx_hash
, et.from AS tx_from
, et.to AS tx_to
, 0 AS platform_fee_amount_raw
, 0 AS platform_fee_amount
, 0 AS platform_fee_amount_usd
, 0 AS platform_fee_percentage
, COALESCE(get_json_object(bm.buy, '$.price')*get_json_object(get_json_object(bm.sell, '$.fees[0]'), '$.rate')/10000, 0) AS royalty_fee_amount_raw
, CASE WHEN get_json_object(bm.buy, '$.paymentToken')='0x0000000000000000000000000000000000000000' THEN COALESCE(get_json_object(bm.buy, '$.price')/POWER(10, 18)*get_json_object(get_json_object(bm.sell, '$.fees[0]'), '$.rate')/10000, 0)
    ELSE COALESCE(get_json_object(bm.buy, '$.price')/POWER(10, pu.decimals)*get_json_object(get_json_object(bm.sell, '$.fees[0]'), '$.rate')/10000, 0)
    END AS royalty_fee_amount
, CASE WHEN get_json_object(bm.buy, '$.paymentToken')='0x0000000000000000000000000000000000000000' THEN COALESCE(pu.price*get_json_object(bm.buy, '$.price')/POWER(10, 18)*get_json_object(get_json_object(bm.sell, '$.fees[0]'), '$.rate')/10000, 0)
    ELSE COALESCE(pu.price*get_json_object(bm.buy, '$.price')/POWER(10, pu.decimals)*get_json_object(get_json_object(bm.sell, '$.fees[0]'), '$.rate')/10000, 0)
    END AS royalty_fee_amount_usd
, COALESCE(get_json_object(get_json_object(bm.sell, '$.fees[0]'), '$.rate')/100, 0) AS royalty_fee_percentage
, get_json_object(get_json_object(bm.sell, '$.fees[0]'), '$.recipient') AS royalty_fee_receive_address
, CASE WHEN get_json_object(get_json_object(bm.sell, '$.fees[0]'), '$.recipient') IS NOT NULL AND get_json_object(bm.buy, '$.paymentToken')='0x0000000000000000000000000000000000000000' THEN 'ETH'
    WHEN get_json_object(get_json_object(bm.sell, '$.fees[0]'), '$.recipient') IS NOT NULL THEN pu.symbol
    END AS royalty_fee_currency_symbol
,  'ethereum-blur-v1' || bm.evt_tx_hash || '-' || COALESCE(taker_fix.from, get_json_object(bm.sell, '$.trader')) || '-' || COALESCE(maker_fix.to, get_json_object(bm.buy, '$.trader')) || '-' || get_json_object(bm.buy, '$.collection') || '-' || get_json_object(bm.buy, '$.tokenId') AS unique_trade_id
FROM {{ source('blur_ethereum','BlurExchange_evt_OrdersMatched') }} bm
LEFT JOIN {{ source('ethereum','transactions') }} et ON et.block_time=bm.evt_block_time
    AND et.hash=bm.evt_tx_hash
    {% if is_incremental() %}
    AND et.block_time >= date_trunc("day", now() - interval '1 week')
    {% endif %}
LEFT JOIN {{ ref('nft_ethereum_aggregators') }} agg ON agg.contract_address=et.to
LEFT JOIN {{ source('prices','usd') }} pu ON pu.blockchain='ethereum'
    AND pu.minute=date_trunc('minute', bm.evt_block_time)
    AND (pu.contract_address=get_json_object(bm.buy, '$.paymentToken')
        OR (pu.contract_address='0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2' AND get_json_object(bm.buy, '$.paymentToken')='0x0000000000000000000000000000000000000000'))
    {% if is_incremental() %}
    AND pu.minute >= date_trunc("day", now() - interval '1 week')
    {% endif %}
LEFT JOIN {{ ref('tokens_ethereum_nft') }} nft ON get_json_object(bm.buy, '$.collection')=nft.contract_address
LEFT JOIN {{ source('erc721_ethereum','evt_transfer') }} erct ON erct.evt_block_time=bm.evt_block_time
    AND get_json_object(bm.buy, '$.collection')=erct.contract_address
    AND erct.evt_tx_hash=bm.evt_tx_hash
    AND get_json_object(bm.buy, '$.tokenId')=erct.tokenId
    AND erct.from=get_json_object(bm.sell, '$.trader')
    {% if is_incremental() %}
    AND erct.evt_block_time >= date_trunc("day", now() - interval '1 week')
    {% endif %}
LEFT JOIN {{ source('erc721_ethereum','evt_transfer') }} maker_fix ON maker_fix.evt_block_time=bm.evt_block_time
    AND get_json_object(bm.buy, '$.collection')=maker_fix.contract_address
    AND maker_fix.evt_tx_hash=bm.evt_tx_hash
    AND get_json_object(bm.buy, '$.tokenId')=maker_fix.tokenId
    AND maker_fix.from=agg.contract_address
    {% if is_incremental() %}
    AND maker_fix.evt_block_time >= date_trunc("day", now() - interval '1 week')
    {% endif %}
LEFT JOIN {{ source('erc721_ethereum','evt_transfer') }} taker_fix ON taker_fix.evt_block_time=bm.evt_block_time
    AND get_json_object(bm.buy, '$.collection')=taker_fix.contract_address
    AND taker_fix.evt_tx_hash=bm.evt_tx_hash
    AND get_json_object(bm.buy, '$.tokenId')=taker_fix.tokenId
    AND taker_fix.to=agg.contract_address
    {% if is_incremental() %}
    AND taker_fix.evt_block_time >= date_trunc("day", now() - interval '1 week')
    {% endif %}
{% if is_incremental() %}
WHERE bm.evt_block_time >= date_trunc("day", now() - interval '1 week')
{% endif %}